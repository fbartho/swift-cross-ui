import Foundation
import ImageFormats
@_spi(Backends) import SwiftCrossUI
import SwiftCrossUIComponents

/// Serializes a committed widget tree into HTML.
///
/// Element choice runs through three layers, in order:
///
/// 1. An explicit ``View/htmlTag(_:)`` on the view, which always wins.
/// 2. A heading derived from the author's declared text style, via
///    ``HeadingMap``.
/// 3. A `div` (or `span` for text) carrying an ARIA role where the widget's
///    type implies one.
///
/// Nothing outside those three layers gets to influence semantics. Geometry
/// and styling never do.
///
/// ## Flow, not coordinates
///
/// The layout system produces an exact position and size for every widget, but
/// emitting those directly would produce a document that only looks right at
/// the width it was laid out against: text that the browser wraps differently
/// than the build host estimated would overflow its pinned box, and nothing
/// would reflow when the reader resizes the window or opens the page on a
/// phone. This tier is what crawlers and readers without JavaScript get, so it
/// reflows.
///
/// Containers the layout system describes as stacks (see
/// ``StaticHTMLBackend/Container/stackLayout``) are therefore re-expressed as
/// CSS flex containers — direction, `gap`, and alignment carry the arrangement
/// — and their children take their natural size. The committed geometry is
/// still used where CSS has nothing to derive a size from, and absolute
/// positioning remains for containers that were never described as stacks,
/// which is the only construct flow can't express.
///
/// The result is best-effort: it drifts from the native rendering, which is
/// accepted. Overlapping or non-reflowing output is not.
@MainActor
public struct HTMLEmitter {
    /// The mapping from declared text styles to heading elements.
    public var headingMap: HeadingMap
    /// The interner that collapses duplicate styles into shared classes.
    public var interner = StyleInterner()
    /// The palette that turns scheme-varying colors into custom properties.
    public var palette = ColorPalette()
    /// The type scale that turns declared text styles into custom properties.
    public var typeScale = TypeScale()
    /// The registry the view tree's contributions were registered into.
    ///
    /// Read during emission to fill custom slots, whose items have to be in
    /// hand as the emitter reaches the ``HTMLSlot`` marking them.
    ///
    /// It is also where the emitter would register machinery for the core's own
    /// views, which cannot contribute for themselves: a retroactive conformance
    /// to ``HTMLDocumentContributing`` on a core view would never fire, since
    /// the core's update loop knows nothing about the protocol. Nothing
    /// registers that way yet.
    public var registry: HTMLFragmentRegistry?
    /// Where asset bytes are published, and the size below which they're
    /// inlined instead.
    var assetStores = HTMLAssetStores()
    var inlineAssetThreshold: Int?
    /// What turns asset bytes into the reference the document carries.
    var assetResolver: HTMLAssetResolver {
        HTMLAssetResolver(stores: assetStores, inlineThreshold: inlineAssetThreshold)
    }
    /// Whether to write the `data-scui` attribute naming each element's view
    /// type. See ``DocumentContext/emitsViewIdentity``, which sets it — and
    /// which documents why the `data-scui-*` protocol markers are not
    /// governed by it.
    var emitsViewIdentity = true
    /// The custom slot names the document declared, for validating
    /// ``HTMLSlot`` markers as they're encountered.
    var declaredSlots: Set<String> = []
    /// The slot names a ``HTMLSlot`` marker was actually found for.
    ///
    /// Collected during emission so the renderer can report a declared slot
    /// whose items would otherwise be silently dropped.
    private(set) var encounteredSlots: Set<String> = []
    /// The document's heading outline, collected in document order as
    /// ``HeadingMap`` derives each heading element.
    ///
    /// Populated from the same signal that decides the emitted element (see
    /// the `Text` case below), so the outline and the markup can never
    /// disagree about what counts as a heading.
    private(set) var headings: [DocumentInfo.Heading] = []
    /// The view type tag of every `Image` emitted with no author-supplied
    /// `alt`, in document order.
    ///
    /// Populated at the same site that falls back to `alt=""` — see the
    /// `ImageView` case below — so this list and the emitted markup can never
    /// disagree about which images went undescribed. Surfaced on
    /// ``DocumentInfo/imagesMissingAltText`` since no linter can detect the
    /// fallback by reading the markup itself: an empty `alt` is
    /// indistinguishable from one an author deliberately set.
    private(set) var imagesMissingAltText: [String] = []

    /// How a parent is positioning one of its children.
    public enum Placement: Hashable, Sendable {
        /// The browser places the element, which is the usual case. The
        /// element's size comes from its content and from whatever the parent's
        /// flow rules impose.
        case flow
        /// The element is pinned to the coordinates the layout system committed
        /// for it. Used only where flow can't express the arrangement.
        case absolute
        /// The element is absolutely positioned but stretched to cover its
        /// positioned ancestor's box (`inset:0`) rather than pinned to the
        /// build-host's committed px size. Used for a
        /// ``SwiftCrossUI/View/background(_:)`` backdrop specifically (see
        /// ``StaticHTMLBackend/Container/isBackgroundLayering``): the
        /// backdrop has no content of its own to size itself from, so it has
        /// to track whatever box the foreground box ends up being — which
        /// ``absolute``'s baked width/height can't do once that box reflows
        /// at a width other than the one the layout system happened to
        /// propose.
        case backgroundStretch
    }

    /// Creates an emitter.
    ///
    /// - Parameter headingMap: The mapping to derive headings with.
    public init(headingMap: HeadingMap = .default) {
        self.headingMap = headingMap
    }

    /// A size an enclosing frame declared for a widget specifically, rather
    /// than for a wrapper around it.
    ///
    /// Each axis is independently optional because a frame only ever
    /// constrains the axes the author actually wrote down — see
    /// ``StrictFrameView``, where an omitted `width`/`height` stays `nil` all
    /// the way through. Collapsing both axes into one always-present size
    /// (falling back to the committed, possibly-stretched size for whichever
    /// axis wasn't declared) is exactly the bug this type exists to avoid:
    /// see the min-width note on ``HTMLEmitter/pin(size:in:placement:)``.
    public struct InheritedFrame: Hashable, Sendable {
        /// The declared width, or `nil` if the frame left this axis alone.
        public var width: Int?
        /// The declared height, or `nil` if the frame left this axis alone.
        public var height: Int?
    }

    /// What the enclosing element is allowed to contain.
    ///
    /// Most HTML elements take flow content, so any wrapper the view tree
    /// produced is legal inside them. A few restrict their children to
    /// specific element names — `<ul>`/`<ol>` take only `<li>` — and there the
    /// structural wrappers a `ForEach` body expands to would make the markup
    /// invalid: the items stop being the list's children, so the list has no
    /// items and each item has no list.
    public enum ChildContentModel: Sendable {
        /// Anything may appear here.
        case flow
        /// Only these element names may appear here, and a wrapper carrying
        /// none of them is spliced away rather than emitted.
        case only(Set<String>)

        /// The content model that applies to a given element's children.
        ///
        /// - Parameter element: The element being emitted.
        /// - Returns: What that element may contain.
        static func forChildren(of element: HTMLElement) -> ChildContentModel {
            switch element.name {
                case "ul", "ol", "menu": .only(["li", "script", "template"])
                default: .flow
            }
        }

        /// Whether a widget's own element has to be spliced away to keep the
        /// enclosing element's content model valid.
        ///
        /// Only a wrapper qualifies. A leaf carrying a disallowed element is
        /// the author's own doing — a `Text` under a `ul` with no `.htmlTag`
        /// on it, say — and dropping it would lose content, so it's emitted
        /// as written and left for a validator to report.
        func excludes(_ widget: StaticHTMLBackend.Widget, emitter: HTMLEmitter) -> Bool {
            guard case .only(let allowed) = self else {
                return false
            }
            let children = widget.getChildren()
            guard !children.isEmpty else {
                return false
            }
            let element = widget.explicitElement ?? .div
            return !allowed.contains(element.name)
        }
    }

    /// Emits a widget and its descendants.
    ///
    /// - Parameters:
    ///   - widget: The widget to emit.
    ///   - origin: The widget's position relative to its parent. Only consulted
    ///     when `placement` is ``Placement/absolute``; under flow the browser
    ///     decides where the element lands.
    ///   - placement: How the parent is positioning this widget.
    ///   - indentLevel: How far to indent the emitted markup.
    ///   - inheritedFrame: The size an enclosing frame declared for this
    ///     widget specifically, rather than for a wrapper around it. A void
    ///     element (``HTMLElement/isVoid``) honors both axes unconditionally:
    ///     those elements size themselves from their replaced content, not
    ///     from CSS layout, so a frame around one has nothing to apply itself
    ///     to except the element directly. A leaf with nothing inside it to
    ///     derive a size from (``StaticHTMLBackend/Rectangle``) honors only
    ///     the axes that were actually declared, falling back to its own
    ///     committed size for the rest. See
    ///     ``HTMLEmitter/emitChildren(of:style:indent:indentLevel:)``.
    ///   - stretchesUndeclaredAxis: Whether an ancestor's undeclared frame
    ///     axis (Divider, specifically) should be filled by this widget's
    ///     subtree rather than floored to committed size. Threaded down
    ///     explicitly because the leaf that finally acts on it is several
    ///     levels below whichever ancestor actually was marked — see the
    ///     widget.isDivider check at the top of this function (set by
    ///     ``BackendFeatures/Widgets/describeDivider(of:)``), and the
    ///     matching flex/align-self handling in
    ///     ``HTMLEmitter/emitChildren(of:style:indent:indentLevel:stretchesUndeclaredAxis:)``.
    ///   - priorityAllocation: The layout-priority-derived flex declarations
    ///     for this widget specifically, when it's a direct child of a stack
    ///     whose children didn't all share the same
    ///     ``SwiftCrossUI/View/layoutPriority(_:)``. See
    ///     ``HTMLEmitter/priorityAllocations(of:orientation:)``.
    ///   - parentIsFlex: Whether the element this widget will be emitted
    ///     inside is a flex container. Consulted only by
    ///     ``HTMLEmitter/elidableContainer(_:placement:parentIsFlex:)``, whose
    ///     guard is a property of the surviving parent rather than of the
    ///     wrapper being considered — see that method for why.
    /// - Returns: The widget's markup.
    public mutating func emit(
        _ widget: StaticHTMLBackend.Widget,
        at origin: SIMD2<Int>,
        placement: Placement = .flow,
        indentLevel: Int = 0,
        inheritedFrame: InheritedFrame? = nil,
        stretchesUndeclaredAxis: Bool = false,
        priorityAllocation: PriorityAllocation? = nil,
        childContentModel: ChildContentModel = .flow,
        parentIsFlex: Bool = false
    ) -> String {
        let indent = String(repeating: "  ", count: indentLevel + 1)

        // A list element may only contain list items, so a structural wrapper
        // that would land between them has to go — not merely be hidden.
        // display:contents removes a box from layout but leaves the element in
        // the DOM, which is what an `<ul>`'s content model, and every
        // assistive technology reading it, actually objects to. Splicing the
        // wrapper's children into its place is the only fix that makes the
        // emitted markup valid.
        //
        // This is not subsumed by the elision rule below, which answers a
        // different question: elision asks whether an element does any work,
        // and a wrapper under a `<ul>` is refused there precisely because the
        // list is not a flex container, so its child's sizing would change.
        // Validity is the stronger claim, and it holds whatever the style
        // says — so the two rules coexist rather than one retiring the other.
        if childContentModel.excludes(widget, emitter: self) {
            return emitChildren(
                widget.getChildren().map { ($0, SIMD2<Int>.zero) },
                placement: .flow,
                indent: indent,
                indentLevel: indentLevel - 1,
                childContentModel: childContentModel
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        }

        // A wrapper carrying no function is spliced away, its children taking
        // its place at its own indent level. Decided before the switch below
        // emits anything: the children have to be built at the depth they end
        // up at, since re-indenting finished markup would rewrite the
        // significant whitespace inside a `<pre>`.
        if let elided = elidableContainer(
            widget,
            placement: placement,
            priorityAllocation: priorityAllocation,
            parentIsFlex: parentIsFlex
        ) {
            return emitChildren(
                elided.children,
                placement: .flow,
                indent: indent,
                indentLevel: indentLevel - 1,
                stretchesUndeclaredAxis: stretchesUndeclaredAxis,
                childContentModel: childContentModel,
                parentIsFlex: parentIsFlex
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        }

        // A raw fragment or slot marker replaces the element entirely — the
        // zero-size leaf the view produced exists only to carry the payload
        // here, so emitting a box around it would put a stray div in the
        // document.
        if let fragment = widget.rawFragment {
            if let slotName = fragment.slotName {
                encounteredSlots.insert(slotName)
                precondition(
                    declaredSlots.contains(slotName),
                    """
                    HTMLSlot("\(slotName)") has no matching slot on the \
                    document context. Declare it with \
                    DocumentContext.withSlot("\(slotName)") — an undeclared \
                    name is a typo, and emitting nothing here would hide it.
                    """
                )
                let items = registry?.items(in: .custom(slotName)) ?? []
                let resolver = assetResolver
                return items
                    .map { $0.rendered(indent: indent, resolver: resolver) }
                    .joined(separator: "\n")
            }
            return "\(indent)\(fragment.html)"
        }

        var style = Style()
        if let priorityAllocation {
            // A shrink-only child leaves flex-basis at auto, keeping its
            // own natural/committed size as the starting point it shrinks
            // from — the same "committed size is the reflow starting point"
            // principle this emitter applies elsewhere (Rectangle's
            // fallback, for one). A bare flex-shrink declaration doesn't
            // imply flex-basis:0% the way the `flex` shorthand would, so
            // that default survives unless the grow branch below overrides
            // it.
            style.set("\(Self.formatNumber(priorityAllocation.shrink))", for: "flex-shrink")

            if let grow = priorityAllocation.grow,
               let minimum = priorityAllocation.minimum,
               let maximum = priorityAllocation.maximum
            {
                let axis = priorityAllocation.orientation == .horizontal
                    ? "width" : "height"
                style.set("\(Self.formatNumber(grow))", for: "flex-grow")
                style.set("\(Self.formatNumber(minimum))px", for: "min-\(axis)")
                // Growth starts from the floor rather than from the child's
                // committed size, so the weights divide the whole surplus
                // instead of whatever the build-host measurement left over.
                style.set("\(Self.formatNumber(minimum))px", for: "flex-basis")
                if maximum.isFinite {
                    style.set("\(Self.formatNumber(maximum))px", for: "max-\(axis)")
                }
            }
        }
        if placement == .absolute {
            style.set("absolute", for: "position")
            style.set("\(origin.x)px", for: "left")
            style.set("\(origin.y)px", for: "top")
            style.set("\(widget.size.x)px", for: "width")
            style.set("\(widget.size.y)px", for: "height")
        }
        if placement == .backgroundStretch {
            // inset:0, not baked coordinates: the backdrop has to cover
            // whatever box the positioned ancestor ends up being at the
            // reader's width, not the one the build host committed. See
            // ``HTMLEmitter/Placement/backgroundStretch``.
            style.set("absolute", for: "position")
            style.set("0", for: "inset")
            // A positioned element paints above its unpositioned in-flow
            // siblings whatever the tree order says (CSS 2.1 Appendix E:
            // positioned/z-index:auto is step 8, in-flow blocks are step 4
            // and inline content step 7), and this backdrop's sibling is
            // the foreground in flow. z-index:-1 moves it to step 3, below
            // both. The wrapper isolates so it can't sink past the
            // ancestors' backgrounds too — see the isBackgroundLayering
            // branch in
            // ``HTMLEmitter/emitChildren(of:style:indent:indentLevel:stretchesUndeclaredAxis:)``.
            style.set("-1", for: "z-index")
        }
        if widget.cornerRadius > 0 {
            style.set("\(widget.cornerRadius)px", for: "border-radius")
            // border-radius alone only rounds this element's own background
            // and border; descendants keep painting square over the rounded
            // corners. The native backends all pair the radius with a clip
            // (AppKit's clipsToBounds, UIKit's masksToBounds), so a
            // .background() backdrop — absolutely positioned at inset:0 with
            // a radius of its own of 0 — needs the same treatment here or it
            // fills the corners the radius was meant to cut.
            style.set("hidden", for: "overflow")
        }
        if widget.isDivider {
            // Divider's documented behaviour is to expand along the minor
            // axis of its containing stack, but the flex model this emitter
            // otherwise relies on centers cross-axis children by default
            // (see StaticHTMLRenderer's VStack test, which defaults to
            // .center) — the same shrink-to-fit sizing every other stack
            // child gets. align-self:stretch overrides that for this one
            // element regardless of what alignment the parent stack
            // declared, matching the one-off "always expands, whatever the
            // container's alignment says" contract Divider actually
            // documents. It's harmless when Divider isn't inside a flex
            // container at all — align-self is simply ignored there.
            style.set("stretch", for: "align-self")
        }

        var element = HTMLElement.div
        var role: String?
        var inner = ""
        var isRawInner = false
        // The children are emitted inside the switch below, before `element`
        // is finally resolved, so the model they're emitted under has to come
        // from what's already known here. Only an explicit tag can introduce a
        // restrictive model — nothing the switch derives on its own is a list
        // element — so reading the request directly is enough, and it stays
        // correct even where an explicit tag later overrides a derived one.
        let childModel =
            widget.explicitElement.map { ChildContentModel.forChildren(of: $0) } ?? .flow
        // Set when this widget's declared text style implied a heading
        // element — recorded provisionally, appended to `headings` after the
        // explicit-tag override below is resolved, so the outline agrees
        // with what's actually emitted rather than with this intermediate
        // guess.
        var headingCandidate: DocumentInfo.Heading?
        // Attributes a control case needs beyond what every widget already
        // gets (role, data-scui, class, ...) — checked/value/min/max/etc.
        // Kept separate from `attributes` below so author attributes are
        // still merged first and can't be clobbered by a backend-owned one.
        var controlAttributes: [String: String] = [:]
        // Backend-owned classes that name a shared, hand-written rule rather
        // than an interned declaration set. Kept out of `style` because the
        // interner keys on declarations: a variant whose whole point is to be
        // one named rule reused across every button would otherwise be
        // duplicated into a distinct class per button.
        var extraClasses: [String] = []

        switch widget {
            case let text as StaticHTMLBackend.TextView:
                element = .span
                if let font = text.font {
                    // A bare text style rides the type scale's custom
                    // properties, so its size responds to viewport width and
                    // every element sharing that style collapses into one
                    // interned class. Anything else — an explicit point size,
                    // or a style carrying a modifier — keeps literal pixels.
                    if let textStyle = Self.textStyle(for: text.declaredFont) {
                        let values = typeScale.values(for: textStyle)
                        style.set(values.fontSize, for: "font-size")
                        style.set(values.lineHeight, for: "line-height")
                        style.set(values.weight, for: "font-weight")
                    } else {
                        style.set("\(Int(font.pointSize))px", for: "font-size")
                        style.set("\(Int(font.lineHeight))px", for: "line-height")
                        style.set(Self.cssWeight(font.weight), for: "font-weight")
                    }
                    if font.isItalic {
                        style.set("italic", for: "font-style")
                    }
                    if font.design == .monospaced {
                        style.set("monospace", for: "font-family")
                    }
                }
                if let color = text.color {
                    style.set(palette.value(for: color), for: "color")
                }
                style.set("pre-wrap", for: "white-space")
                // Every declared alignment is written, including .leading —
                // not just the non-default cases — because the style is what
                // the interner keys off. Skipping the default would collapse
                // a .leading Text into the same class as one with no
                // alignment declared at all, but the two aren't the same
                // question: the point is that .center and .trailing must
                // reach the stylesheet, and the only way that's reliable is
                // writing the whole enum through uniformly.
                style.set(Self.cssTextAlign(text.textAlignment), for: "text-align")
                if !text.isTextSelectionEnabled {
                    // Only the disabled case is written: user-select's CSS
                    // default is already selectable text, so a widget that
                    // never touched the modifier stays unstyled instead of
                    // interning a redundant "user-select:text" rule.
                    style.set("none", for: "user-select")
                }
                if let lineLimit = text.lineLimit {
                    style.set("hidden", for: "overflow")
                    style.set("\(lineLimit.limit)", for: "-webkit-line-clamp")
                    style.set("-webkit-box", for: "display")
                    style.set("vertical", for: "-webkit-box-orient")
                    if lineLimit.reservesSpace, let font = text.font {
                        // reservesSpace holds the box open to the full
                        // line-limit height even when the actual content is
                        // shorter, so the reserved floor has to come from
                        // the limit itself rather than from the committed
                        // (possibly shorter) layout size.
                        style.set(
                            "\(Int(font.lineHeight) * lineLimit.limit)px",
                            for: "min-height"
                        )
                    }
                }
                inner = Self.escape(text.content)
                // A declared text style is the author saying what this line is
                // for, so it outranks the generic span — everywhere except
                // inside a control's label. A label's declared style says how
                // the label should look, the same reason any other Text
                // carries one; it says nothing about document structure, so
                // it's never read as heading intent there. Left unguarded,
                // any label styled with a heading-mapped font (a nav button
                // using .title2, say) would leak into the outline as if it
                // were a section heading, and the control itself would emit
                // as an `<h3>` rather than the `<button>`/`<a>` its emission
                // matrix chose.
                if !widget.isInsideControlLabel,
                   let derived = headingMap.element(for: text.declaredFont)
                {
                    element = derived
                    // Recorded provisionally — an explicit .htmlTag() override
                    // below can still replace `element`, and the outline
                    // should agree with what's actually emitted rather than
                    // with this intermediate guess.
                    if let level = derived.headingLevel {
                        headingCandidate = DocumentInfo.Heading(level: level, text: text.content)
                    }
                }

            case let button as StaticHTMLBackend.SimpleButton:
                // Tier-activation principle: an element is live at this tier
                // only if pure HTML/CSS can resolve what it does. A
                // navigation-intent href IS resolvable in pure HTML — the
                // browser handles it with no script — so a Button carrying
                // one emits as a real, live `<a href>` (href-only and
                // href+action rows). A click action has nothing pure HTML
                // can resolve, so absent an href the button emits inert:
                // a real `<button disabled>`, not a link dressed up with
                // `role="button"` and a `href="#"` placeholder — that used
                // to look reachable to a keyboard, crawler, or assistive
                // technology exactly like a working control would. Reviving
                // it is a later tier's job, flagged by data-scui-enliven.
                //
                // Emission matrix:
                //   href-only    -> live <a href>                    (this branch)
                //   action-only  -> <button type="button" disabled>  (isEnabled-driven branch below)
                //   href+action  -> live <a href> + enliven, no disabled
                //
                // The href+action row is legal — a Button may carry both a
                // .href and a click action (e.g. an analytics-tracked link).
                // The emitted <a href> stays alive (never disabled: the link
                // half is pure-HTML-resolvable on its own), and also carries
                // data-scui-enliven so a later tier can attach the handler.
                // That handler-attachment code (not written here — there is
                // no JS in this tier) MUST honor the modified-click contract:
                // a plain left-click should preventDefault and run the
                // action; a modified click (cmd/ctrl/shift/middle-click —
                // open-in-new-tab and friends) must fall through to native
                // link behaviour untouched, so the link stays a real link
                // even once enlivened.
                //
                // Ambiguity resolved here: nothing distinguishes href-only
                // from href+action at this layer. `Button.init(_:action:)`
                // defaults `action` to an empty closure, so "no action" and
                // "a real no-op action" are indistinguishable both at the
                // View layer and on the widget (the button widgets don't even
                // retain the closure — see `updateSimpleButton`/`updateButton`).
                // Marking every href-carrying Button with the enliven marker
                // — rather than trying to guess which ones are "really"
                // href-only — is the honest choice: a hydration tier that
                // finds nothing to bind for a true href-only Button simply
                // no-ops, whereas omitting the marker for a Button that DOES
                // have a real action would silently drop it forever.
                if let href = widget.href {
                    element = .custom("a")
                    controlAttributes["href"] = href
                    controlAttributes["data-scui-enliven"] = "js"
                } else {
                    element = .custom("button")
                    controlAttributes["type"] = "button"
                    controlAttributes["data-scui-enliven"] = "js"
                }
                extraClasses.append(button.style.className)
                style.set("inline-flex", for: "display")
                style.set("center", for: "align-items")
                style.set("center", for: "justify-content")
                style.set("border-box", for: "box-sizing")
                // Underlining is left to the reset's `a[href]` rule rather
                // than suppressed here. A Button that resolved to a live
                // anchor is a link the reader can follow, and the underline
                // is the affordance that says so; the `<button>` row has no
                // such rule, so it stays undecorated without declaring it.
                inner = Self.escape(button.label)

            case let button as StaticHTMLBackend.ViewLabelButton:
                // Same emission matrix as the string-label case above — the
                // tier-activation reasoning is identical and documented there.
                // What differs is the label: this button owns a child subtree
                // rather than a string, so the label is emitted by walking it.
                if let href = widget.href {
                    element = .custom("a")
                    controlAttributes["href"] = href
                    controlAttributes["data-scui-enliven"] = "js"
                } else {
                    element = .custom("button")
                    controlAttributes["type"] = "button"
                    controlAttributes["data-scui-enliven"] = "js"
                }
                extraClasses.append(button.buttonStyle.className)
                style.set("inline-flex", for: "display")
                style.set("center", for: "align-items")
                style.set("center", for: "justify-content")
                style.set("border-box", for: "box-sizing")
                if let text = Self.plainTextLabel(of: button.label) {
                    // A button whose label is just text puts that text
                    // directly inside the control, the way the string-label
                    // case does. Emitting the subtree would nest a styled
                    // span in a layout div for a single run of characters,
                    // and `<button><div><span>` describes structure the
                    // author never wrote.
                    //
                    // Deliberately narrow: only a lone, unstyled Text
                    // qualifies. Anything else — a styled label, an icon
                    // beside a word, a stack — keeps its subtree, because
                    // deciding in general which wrappers carry no meaning is
                    // the elision design's question, not this one's.
                    inner = Self.escape(text)
                } else {
                    inner = emitChildren(
                        [(button.label, .zero)],
                        placement: .flow,
                        indent: indent,
                        indentLevel: indentLevel,
                        childContentModel: childModel,
                        // The control is display:inline-flex, set above.
                        parentIsFlex: true
                    )
                    isRawInner = true
                }

            case let checkbox as StaticHTMLBackend.Checkbox:
                // Bindings are dead without a runtime (uniform-application
                // consequence of the tier-activation principle): a checkbox
                // the reader ticks here has nothing to write the change back
                // to, so it loads disabled + enlivened like every other
                // control whose interactivity depends on a tier that isn't
                // present yet. checked/aria-checked still reflect the bound
                // value — the *display* is real, only the *interaction*
                // isn't, until a later tier lifts disabled.
                element = .custom("input")
                controlAttributes["type"] = "checkbox"
                controlAttributes["aria-checked"] = checkbox.state ? "true" : "false"
                controlAttributes["data-scui-enliven"] = "js"
                if checkbox.state {
                    controlAttributes["checked"] = "checked"
                }
                style.set("14px", for: "width")
                style.set("14px", for: "height")

            case let toggleSwitch as StaticHTMLBackend.Switch:
                // HTML has no native switch input, so the standard
                // accessible pattern is a `role="switch"` on a focusable
                // element carrying `aria-checked`. `<button>` is the
                // natively-focusable choice. Its binding is dead without a
                // runtime the same as Checkbox above, so it loads disabled +
                // enlivened too.
                element = .custom("button")
                role = "switch"
                controlAttributes["type"] = "button"
                controlAttributes["aria-checked"] = toggleSwitch.state ? "true" : "false"
                controlAttributes["data-scui-enliven"] = "js"
                style.set("28px", for: "width")
                style.set("16px", for: "height")

            case let toggleButton as StaticHTMLBackend.ToggleButton:
                element = .custom("button")
                controlAttributes["type"] = "button"
                controlAttributes["aria-pressed"] = toggleButton.state ? "true" : "false"
                controlAttributes["data-scui-enliven"] = "js"
                // A toggle button is a button, so it takes the same default
                // chrome; without it the reset leaves it as bare text, which
                // is the one thing a control named for a button can't look
                // like. Pressed state comes from the aria-pressed rule.
                extraClasses.append(ButtonStyle.bordered.className)
                if let font = toggleButton.font {
                    style.set("\(Int(font.pointSize))px", for: "font-size")
                    style.set("\(Int(font.lineHeight))px", for: "line-height")
                }
                inner = Self.escape(toggleButton.label)

            case let slider as StaticHTMLBackend.Slider:
                element = .custom("input")
                controlAttributes["type"] = "range"
                controlAttributes["min"] = Self.formatNumber(slider.minimumValue)
                controlAttributes["max"] = Self.formatNumber(slider.maximumValue)
                controlAttributes["value"] = Self.formatNumber(slider.value)
                controlAttributes["data-scui-enliven"] = "js"
                style.set("100%", for: "width")

            case let textField as StaticHTMLBackend.TextField:
                element = .custom("input")
                controlAttributes["type"] = textField.isSecure ? "password" : "text"
                controlAttributes["value"] = textField.value
                controlAttributes["data-scui-enliven"] = "js"
                if !textField.placeholder.isEmpty {
                    controlAttributes["placeholder"] = textField.placeholder
                }
                style.set("border-box", for: "box-sizing")
                if let font = textField.font {
                    style.set("\(Int(font.pointSize))px", for: "font-size")
                }

            case let rectangle as StaticHTMLBackend.Rectangle:
                if let color = rectangle.color {
                    style.set(palette.value(for: color), for: "background-color")
                }
                // A rectangle has nothing inside it to derive a size from, so
                // its committed size is the floor for whichever axis nothing
                // else pinned. An axis an enclosing frame actually declared
                // (Divider's own height:1, for instance) is trusted over the
                // committed one instead.
                //
                // The undeclared axis is where a fixed floor becomes wrong,
                // but only when stretchesUndeclaredAxis says so (true only
                // inside a Divider's subtree — see the isFrame branch in
                // ``HTMLEmitter/emitChildren(of:style:indent:indentLevel:stretchesUndeclaredAxis:)``,
                // which switches the wrapper to display:flex specifically so
                // its default stretch sizes this axis instead): Divider's
                // committed width is however far the layout system happened
                // to stretch it at this one render width, an arbitrary value
                // with no relationship worth preserving, so this axis is left
                // with no width declaration of its own and inherits the
                // flex stretch entirely.
                //
                // An author-declared aspect ratio (``declaredAspectRatio``)
                // is the third case: unlike Divider's stretch, the undeclared
                // axis isn't left to a flex ancestor's default — CSS
                // aspect-ratio derives it directly from whichever axis IS
                // declared, so it stays correct under reflow at any width,
                // not just the one the build host happened to propose.
                // Emitting the committed geometry instead would be exact only
                // for a fixed frame; under this emitter's reflow philosophy a
                // ratio declared on flexible-width content must scale
                // proportionally in the browser rather than bake the one
                // committed outcome as a floor.
                if let ratio = rectangle.declaredAspectRatio {
                    style.set(Self.formatNumber(ratio), for: "aspect-ratio")
                }
                Self.pin(
                    size: rectangle.size,
                    in: &style,
                    placement: placement,
                    declaredWidth: inheritedFrame?.width,
                    declaredHeight: inheritedFrame?.height,
                    hasEnclosingFrame: stretchesUndeclaredAxis
                        || rectangle.declaredAspectRatio != nil
                )

            case let path as StaticHTMLBackend.PathWidget:
                // A shape reaches the backend as flattened path actions with no
                // record of which shape view produced them (see
                // ``StaticHTMLBackend/Path``), so there is nothing to match on
                // that would let the five built-in shapes become border-radius.
                // SVG represents the actions themselves, which is also what
                // makes shapes SwiftCrossUI doesn't ship work without further
                // cases here.
                element = .custom("svg")
                // The path's coordinates are in the committed box's own space,
                // so the viewBox is that box: the geometry then scales with
                // whatever width the browser reflows the element to instead of
                // being pinned to the build host's measurement.
                controlAttributes["viewBox"] = "0 0 \(path.size.x) \(path.size.y)"
                controlAttributes["xmlns"] = "http://www.w3.org/2000/svg"
                // A shape is decorative unless the author says otherwise; an
                // unlabelled graphic would otherwise be announced as an
                // unnamed image.
                if Self.scalarAuthorAttribute(path.authorAttributes, "role") == nil
                    && Self.scalarAuthorAttribute(path.authorAttributes, "aria-label") == nil
                {
                    controlAttributes["aria-hidden"] = "true"
                }
                Self.pin(
                    size: path.size,
                    in: &style,
                    placement: placement,
                    declaredWidth: inheritedFrame?.width,
                    declaredHeight: inheritedFrame?.height
                )

                var pathAttributes = ["d": path.pathData]
                // Shape's default is a clear stroke and a foreground-colored
                // fill, and a styled shape leaves whichever half the author
                // didn't set clear (see ``SwiftCrossUI/StyledShape``'s commit).
                // Writing a fully transparent paint would emit a paint server
                // that renders nothing under both schemes and interns a class
                // per unused color, so an invisible half becomes `none`.
                if let fillColor = path.fillColor, Self.isVisible(fillColor) {
                    pathAttributes["fill"] = palette.value(for: fillColor)
                } else {
                    pathAttributes["fill"] = "none"
                }
                if path.fillRule == .evenOdd {
                    pathAttributes["fill-rule"] = "evenodd"
                }
                if path.strokeWidth > 0, let strokeColor = path.strokeColor,
                   Self.isVisible(strokeColor)
                {
                    pathAttributes["stroke"] = palette.value(for: strokeColor)
                    pathAttributes["stroke-width"] = Self.formatNumber(path.strokeWidth)
                    pathAttributes["stroke-linecap"] = Self.cssLineCap(path.strokeCap)
                    pathAttributes["stroke-linejoin"] = Self.cssLineJoin(path.strokeJoin)
                    if case .miter(let limit) = path.strokeJoin {
                        pathAttributes["stroke-miterlimit"] = Self.formatNumber(limit)
                    }
                }
                let renderedPathAttributes =
                    pathAttributes
                        .sorted { $0.key < $1.key }
                        .map { name, value in " \(name)=\"\(Self.escape(value))\"" }
                        .joined()
                inner = "\n\(indent)  <path\(renderedPathAttributes)/>\n"
                isRawInner = true

            case let gradient as StaticHTMLBackend.GradientWidget:
                // Each stop resolves through the palette independently, so a
                // gradient whose stops differ between schemes rides custom
                // properties for exactly those stops and literals for the
                // rest. The whole gradient is one background-image value, and
                // the interner keys off that string, so two gradients that
                // agree on geometry and every stop share a class.
                let stops = gradient.stops
                    .map { stop in
                        "\(palette.value(for: stop.color))"
                            + " \(Self.formatNumber(stop.location * 100))%"
                    }
                    .joined(separator: ",")
                switch gradient.kind {
                    case .linear(let start, let end):
                        // CSS measures a linear gradient's angle clockwise from
                        // "to top", while the view gives two points in a
                        // y-down space; atan2 of the delta converts between
                        // them.
                        let angle = Self.gradientAngle(from: start, to: end)
                        style.set(
                            "linear-gradient(\(Self.formatNumber(angle))deg,\(stops))",
                            for: "background-image"
                        )
                    case .radial(let center):
                        style.set(
                            "radial-gradient(circle at"
                                + " \(Self.formatNumber(center.x * 100))%"
                                + " \(Self.formatNumber(center.y * 100))%,\(stops))",
                            for: "background-image"
                        )
                    case .angular(let center, let startAngle):
                        style.set(
                            "conic-gradient(from \(Self.formatNumber(startAngle))deg at"
                                + " \(Self.formatNumber(center.x * 100))%"
                                + " \(Self.formatNumber(center.y * 100))%,\(stops))",
                            for: "background-image"
                        )
                }
                if let ratio = gradient.declaredAspectRatio {
                    style.set(Self.formatNumber(ratio), for: "aspect-ratio")
                }
                // A gradient has no content to size itself from, so its
                // committed size is the floor for whichever axis nothing else
                // pinned — the same reasoning as Rectangle above.
                Self.pin(
                    size: gradient.size,
                    in: &style,
                    placement: placement,
                    declaredWidth: inheritedFrame?.width,
                    declaredHeight: inheritedFrame?.height,
                    hasEnclosingFrame: gradient.declaredAspectRatio != nil
                )

            case let image as StaticHTMLBackend.ImageView:
                // PNG round-trips the source's RGBA losslessly, which matters
                // here since there's no author-chosen quality/format to defer
                // to.
                element = .custom("img")
                if !image.rgbaData.isEmpty, image.pixelWidth > 0, image.pixelHeight > 0 {
                    do {
                        let png = try ImageFormats.Image<RGBA>(
                            width: image.pixelWidth,
                            height: image.pixelHeight,
                            bytes: image.rgbaData
                        ).encodeToPNG()
                        controlAttributes["src"] = source(forEncodedImage: png)
                    } catch {
                        // Encoding a well-formed in-memory RGBA buffer to PNG
                        // isn't expected to fail; if it does, a broken image
                        // icon with no src is more honest than silently
                        // dropping back to the empty div this replaces.
                    }
                }
                // No accessibility seam reaches Image (no
                // .accessibilityLabel modifier exists in SwiftCrossUI yet),
                // so alt text is only ever author-supplied via
                // .htmlAttributes(["alt": …]) — merged in below like any
                // other author attribute. Absent that, an empty alt is
                // still required: it's what marks the image decorative
                // rather than leaving assistive tech to read the filename
                // out of a missing attribute. See
                // ``StaticHTMLBackend/ImageView`` for the full policy and
                // ``DocumentInfo/imagesMissingAltText`` for how a page owner
                // discovers which images fell to this default.
                let authorAlt = Self.scalarAuthorAttribute(image.authorAttributes, "alt")
                controlAttributes["alt"] = authorAlt ?? ""
                if authorAlt == nil {
                    imagesMissingAltText.append(image.tag ?? "Image")
                }
                // The size the layout system committed is the one the
                // browser should honor directly, the same reasoning as the
                // inheritedFrame branch below: a void element sizes itself
                // from its replaced content, not from CSS layout, so there's
                // nowhere else to put a declared size except the element
                // itself.
                if image.size.x > 0 {
                    style.set("\(image.size.x)px", for: "width")
                }
                if image.size.y > 0 {
                    style.set("\(image.size.y)px", for: "height")
                }

            case let container as StaticHTMLBackend.Container where container.isSpacer:
                // Spacer has no dedicated Widget subclass of its own — it's a
                // plain empty Container, marked by
                // ``BackendFeatures/Widgets/describeSpacer(of:)`` rather than
                // by type, and the marker is the only thing that identifies
                // one: nothing about its committed geometry says so. Its
                // layoutPriority(-infinity) does reach the backend, in the
                // stack's childLayoutPriorities, and
                // ``HTMLEmitter/priorityAllocations(of:orientation:)`` drops
                // it there so the shorthand below is the whole of what a
                // Spacer gets. flex:1 1 0% reproduces the greedy-but-
                // shrinkable behaviour in the flex model: it grows to fill
                // leftover space and yields before any sibling with a real
                // minimum content size would be squeezed.
                style.set("1 1 0%", for: "flex")

            case let container as StaticHTMLBackend.Container:
                // The stretch signal outlives the specific widget
                // ``BackendFeatures/Widgets/describeDivider(of:)`` marked:
                // Divider composes as `Divider(Container) →
                // StrictFrameView(Container) → Color(Rectangle)`, so a
                // wrapper two levels down from the marked widget still needs
                // to know it's inside a Divider when it constructs its own
                // InheritedFrame for its single child. widget.isDivider
                // starts the signal; the incoming stretchesUndeclaredAxis
                // parameter (already threaded down by an ancestor's own emit
                // call) keeps it alive past that point.
                inner = emitChildren(
                    of: container,
                    style: &style,
                    indent: indent,
                    indentLevel: indentLevel,
                    stretchesUndeclaredAxis: widget.isDivider || stretchesUndeclaredAxis,
                    childContentModel: childModel
                )
                isRawInner = true

            case let table as StaticHTMLBackend.TableWidget:
                return emitTable(table, indent: indent, indentLevel: indentLevel)

            case let splitView as StaticHTMLBackend.SplitViewWidget:
                // Both panes flow side by side and both are readable, which is
                // the whole of what this tier can honour: the divider is the
                // interactive half, and there's no script to drag one with.
                //
                // flex-wrap is what makes the row degrade rather than overflow.
                // The sidebar keeps a flex-basis at its committed width but is
                // allowed to shrink to its min-width; once the detail pane's
                // own minimum no longer fits beside it, the two wrap onto
                // separate lines and the layout becomes stacked — the same
                // narrow-screen shape a native split view collapses to, reached
                // through flow rules rather than a media query, so it responds
                // to the space actually available rather than to a viewport
                // width guessed at build time.
                style.set("flex", for: "display")
                style.set("row", for: "flex-direction")
                style.set("wrap", for: "flex-wrap")
                style.set("stretch", for: "align-items")

                var sidebarStyle = Style()
                sidebarStyle.set("\(Self.defaultSidebarBasis)px", for: "flex-basis")
                sidebarStyle.set("0", for: "flex-grow")
                sidebarStyle.set("1", for: "flex-shrink")
                if let minimum = splitView.minimumSidebarWidth {
                    sidebarStyle.set("\(minimum)px", for: "min-width")
                }
                if let maximum = splitView.maximumSidebarWidth {
                    sidebarStyle.set("\(maximum)px", for: "max-width")
                }

                var detailStyle = Style()
                // The detail pane takes the remaining width, and its
                // flex-basis of 0 with grow:1 is what makes "remaining"
                // mean the whole row minus the sidebar rather than being
                // anchored to its own committed measurement.
                detailStyle.set("1", for: "flex-grow")
                detailStyle.set("1", for: "flex-shrink")
                detailStyle.set("0", for: "flex-basis")
                // Below this the pane is narrower than a readable column, and
                // wrapping to a stacked layout is the better outcome. It's the
                // threshold that actually triggers the flex-wrap above.
                detailStyle.set("\(Self.minimumDetailWidth)px", for: "min-width")

                inner = "\n"
                    + emitPane(
                        splitView.leadingChild,
                        style: sidebarStyle,
                        role: .sidebar,
                        indentLevel: indentLevel + 1
                    ) + "\n"
                    + emitPane(
                        splitView.trailingChild,
                        style: detailStyle,
                        role: .detail,
                        indentLevel: indentLevel + 1
                    ) + "\n"
                isRawInner = true

            case let scroll as StaticHTMLBackend.ScrollContainer:
                style.set("auto", for: "overflow")
                Self.pin(size: scroll.size, in: &style, placement: placement)
                inner = emitChildren(
                    [(scroll.child, .zero)],
                    placement: .flow,
                    indent: indent,
                    indentLevel: indentLevel,
                    childContentModel: childModel
                )
                isRawInner = true

            default:
                let children = widget.getChildren()
                if !children.isEmpty {
                    inner = emitChildren(
                        children.map { ($0, SIMD2<Int>.zero) },
                        placement: .flow,
                        indent: indent,
                        indentLevel: indentLevel,
                        childContentModel: childModel
                    )
                    isRawInner = true
                }
        }

        // An explicit tag is the author overriding everything above.
        if let explicit = widget.explicitElement, explicit.isValid {
            element = explicit
        }
        if let headingCandidate, element.headingLevel == headingCandidate.level {
            headings.append(headingCandidate)
        }

        // A void element is replaced content: the browser sizes it from
        // whatever it turns out to reference (an image file, for instance),
        // not from CSS layout. A frame the author declared around one has no
        // box to apply itself to except the element itself, since a wrapper
        // div does nothing to stretch replaced content to fill it.
        if element.isVoid, let inheritedFrame {
            // Only the axis the frame actually declared is forced: a void
            // element left unconstrained on one axis should still be free to
            // size that axis from its own replaced content (or, for
            // Rectangle below, its committed size) rather than being pinned
            // to whatever the frame's other axis happened to compute to.
            if let width = inheritedFrame.width {
                style.set("\(width)px", for: "width")
            }
            if let height = inheritedFrame.height {
                style.set("\(height)px", for: "height")
            }
        }

        // `class` and `style` resolve against a backend-owned starting point
        // (the interned style class; nothing, for `style`) rather than being
        // merged like every other attribute, so they're excluded here and
        // handled separately below.
        var attributes: [String: String] = Self.resolveAuthorAttributes(
            widget.authorAttributes.filter { $0.key != "class" && $0.key != "style" },
            internedClass: nil
        )
        // Author attributes are merged first so that backend-owned ones
        // overwrite them rather than the other way around.
        for (name, value) in controlAttributes {
            attributes[name] = value
        }
        if let role, attributes["role"] == nil {
            attributes["role"] = role
        }
        if element.name == "a", widget.isEnabled, attributes["href"] == nil {
            // The only remaining `<a>` case with no href by now is an author
            // request via `.htmlTag(.custom("a"))`/similar with nothing
            // resolvable in pure HTML behind it — there is no more implicit
            // `href="#"` placeholder (tier-activation principle: a link with
            // nothing to link to isn't "live", so it shouldn't look
            // activatable). The Button case above only ever reaches `<a>`
            // when `widget.href` is set, which already populated `href`
            // above; this branch exists for that one remaining author-driven
            // path, and it disables rather than fabricating a target.
            attributes["aria-disabled"] = "true"
            attributes["tabindex"] = "-1"
        }
        if element.name == "a", !widget.isEnabled {
            // `.disabled(true)` is a hard author override, regardless of
            // tier: a still image of a disabled control must not keep an
            // activatable target. `<a>` communicates disabled by omitting
            // `href` (it has no `disabled` attribute of its own) — even a
            // widget carrying a live `.href(_:)` loses it here, since the
            // author explicitly said this control shouldn't respond.
            attributes["href"] = nil
        }
        // Floor-disabled: an element carrying the enliven marker has
        // nothing pure HTML/CSS can resolve on its own (tier-activation
        // principle) — its `disabled` has to come from this backend because
        // CSS cannot lift the attribute later; only the arriving tier's own
        // script can remove it, which is exactly what the marker instructs
        // it to do. A live `<a href>` is the one enliven-marked shape that's
        // still exempt: the link half of an href+action Button is
        // pure-HTML-resolvable by itself, so it stays activatable even
        // before any script runs — only the action half is waiting on a
        // tier, and `<a>` has no `disabled` attribute to gate that with
        // anyway.
        let isFloorDisabled =
            attributes["data-scui-enliven"] != nil &&
            !(element.name == "a" && attributes["href"] != nil)
        if !widget.isEnabled || isFloorDisabled {
            // `disabled` is only defined for form-associated elements
            // (button/input); `<a>` communicates the same state by omitting
            // `href` instead, handled above. `aria-disabled` and `tabindex`
            // aren't element-specific, so every disabled control gets them
            // regardless of which of those two paths applies.
            if Self.disablableElementNames.contains(element.name) {
                attributes["disabled"] = "disabled"
            }
            attributes["aria-disabled"] = "true"
            attributes["tabindex"] = "-1"
        }
        // A tap gesture has nothing pure HTML/CSS can resolve, so the element
        // it was attached to is marked for the tier that can bind it. Applied
        // after the floor-disabled rule above, and deliberately outside it:
        // the marked element is ordinary content, not a control, so it gets
        // no `disabled`/`aria-disabled`/`tabindex="-1"` — a <span> the author
        // made tappable is still just a span at this tier, and claiming
        // disabled semantics for it would describe a control that isn't
        // there. Nothing at the floor announces the tap either (no cursor, no
        // role): the affordance arrives with the tier that can honour it.
        //
        // A control that reached here already marked keeps its single marker
        // — `data-scui-enliven` says "this element has interaction waiting on
        // the JS tier", which a tapped Button states once, not twice. The
        // enlivening tier binds whatever that element's widget kind implies,
        // so the control's own action and the tap gesture ride the same flag.
        if widget.awaitsTapEnlivening, attributes["data-scui-enliven"] == nil {
            attributes["data-scui-enliven"] = "js"
        }
        // Written before data-scui so an author attribute of the same name
        // still loses to the backend, matching how every other backend-owned
        // attribute is applied.
        if let identifier = widget.referencedIdentifier {
            attributes["id"] = identifier
        }
        if let labelledBy = widget.labelledBy {
            attributes["aria-labelledby"] = labelledBy
        }
        if let tag = widget.tag, emitsViewIdentity {
            attributes["data-scui"] = tag
        }
        var classNames = extraClasses
        if let interned = interner.className(for: style) {
            classNames.append(interned)
        }
        // An author `class` op applies against the backend's own class list
        // rather than overwriting it — see ``View/htmlAttributes(_:)``'s doc
        // comment. `resolveAuthorAttributes` only knows how to start a
        // token list from a single interned class, so a button style's
        // `extraClasses` are folded into that starting point by hand here
        // instead. Absent a `class` op entirely, the backend's own class
        // list reaches the element unchanged — the classOp check, not a
        // `??` on the resolution, is what tells "no op" apart from "an op
        // that resolved to empty" (e.g. a lone `.remove` of the only class).
        let startingClass = classNames.isEmpty ? nil : classNames.joined(separator: " ")
        let className: String?
        if let classOp = widget.authorAttributes["class"] {
            className = Self.resolveAuthorAttributes(
                ["class": classOp],
                internedClass: startingClass
            )["class"]
        } else {
            className = startingClass
        }
        if let className {
            attributes["class"] = className
        }
        let styleResolution = Self.resolveAuthorAttributes(
            widget.authorAttributes.filter { $0.key == "style" },
            internedClass: nil
        )
        if let inlineStyle = styleResolution["style"] {
            attributes["style"] = inlineStyle
        }

        let renderedAttributes =
            attributes
                .sorted { $0.key < $1.key }
                .map { name, value in " \(name)=\"\(Self.escape(value))\"" }
                .joined()

        guard !element.isVoid else {
            return "\(indent)<\(element.name)\(renderedAttributes)>"
        }

        let body = isRawInner ? "\(inner)\(indent)" : inner
        return "\(indent)<\(element.name)\(renderedAttributes)>\(body)</\(element.name)>"
    }

    /// Whether a widget would emit an element that does no work, and so may be
    /// spliced away in favour of its children.
    ///
    /// An element is written iff it carries function. Function is anything an
    /// author declared (a tag, an attribute, an href, an id, a radius), any
    /// semantics the element name itself provides, and any CSS declaration
    /// that changes what the browser does. What is left over — a `<div>` whose
    /// whole style is the flex trio a single-child stack produces — describes
    /// the view tree's shape rather than the document's, and the reader has no
    /// use for it.
    ///
    /// Two conditions here are not local properties of the wrapper, and both
    /// were established by measurement rather than derived:
    ///
    /// - `align-items` is functional at any child count except at
    ///   `flex-start`. It places the child on the cross axis *within this
    ///   element's own box*, so a lone centered child moves when the wrapper
    ///   goes; only `flex-start` names the position block flow already gives.
    /// - A `display:flex` wrapper may only go when its parent is also flex.
    ///   Whether the child is a flex item or a block box decides both its
    ///   cross-axis sizing (a flex item shrink-wraps; a block box fills) and
    ///   whether an inline child is blockified, and that is settled by
    ///   whichever ancestor survives — hence `parentIsFlex`, not a property of
    ///   this element.
    ///
    /// The test is by construction rather than by inspecting the finished
    /// style: every branch that would contribute a declaration is refused
    /// here, so a future declaration added to the container path cannot
    /// silently become elidable.
    ///
    /// - Parameters:
    ///   - widget: The widget being emitted.
    ///   - placement: How the parent is positioning it. Anything but
    ///     ``Placement/flow`` writes coordinates, which are function.
    ///   - priorityAllocation: The flex declarations the parent stack derived
    ///     for this child, if any. They are real declarations on this
    ///     element, so carrying them is function.
    ///   - parentIsFlex: Whether the surviving parent is a flex container.
    /// - Returns: The container to splice away, or `nil` to emit the element.
    func elidableContainer(
        _ widget: StaticHTMLBackend.Widget,
        placement: Placement,
        priorityAllocation: PriorityAllocation?,
        parentIsFlex: Bool
    ) -> StaticHTMLBackend.Container? {
        guard placement == .flow, priorityAllocation == nil else {
            return nil
        }
        // Only a plain container qualifies. Every other widget kind either
        // carries content of its own or resolves to a non-`div` element, and
        // both are function.
        guard
            let container = widget as? StaticHTMLBackend.Container,
            type(of: widget) == StaticHTMLBackend.Container.self
        else {
            return nil
        }
        // A leaf's content has nowhere to go, and the raw-fragment and spacer
        // paths replace or style the element rather than merely holding
        // children.
        guard
            !container.children.isEmpty, !container.isSpacer, !container.wrapsRawFragment,
            !container.isBackgroundLayering
        else {
            return nil
        }
        // Author intent, a semantic element, and a radius are all function.
        // `carriesNoAuthoredIntent` also refuses a declared frame, which is
        // what keeps every declaredWidth/min/max branch below out of reach.
        //
        // `tag` is deliberately not consulted: `data-scui` is debug identity
        // stamped on every widget, not something an author asked for, so a
        // wrapper that does no work is still elidable with one on it.
        guard container.carriesNoAuthoredIntent else {
            return nil
        }
        // The stretch relay and the infinite-stretch idiom both write real
        // declarations onto this element. The relay condition mirrors the one
        // that actually applies it; the background half of that condition is
        // already excluded above.
        guard !container.relaysChildStretch, !container.declaresInfiniteWidthStretch else {
            return nil
        }
        // A container the layout system never described as a stack reaches
        // the padding, overlap-pin, or plain-splice paths instead; the first
        // two are real boxes and the third is already a splice.
        guard container.stackLayout != nil else {
            return nil
        }
        // A stack of two or more children is a real flex container whose item
        // count would change if it went. At one child, `gap` is never written
        // (see the `children.count > 1` condition guarding it), so a declared
        // spacing has no sibling to space and contributes no declaration.
        guard container.children.count == 1 else {
            return nil
        }
        // At one child the wrapper shrink-wraps, so its own align-items has no
        // slack to place the child within — measured identical across every
        // parent × wrapper alignment pair except a stretching parent, which a
        // stack alignment can never produce: every description resolves through
        // `closestEdge` to flex-start/center/flex-end, custom guides included.
        // What still decides the child's sizing is whichever ancestor survives,
        // hence parentIsFlex.
        guard parentIsFlex else {
            return nil
        }
        return container
    }

    /// Decides how an encoded image reaches the document: as a published file,
    /// or inlined.
    ///
    /// - Parameter png: The encoded image.
    /// - Returns: The value for the element's `src`.
    private func source(forEncodedImage png: [UInt8]) -> String {
        assetResolver.reference(
            for: png,
            fileExtension: "png",
            mediaType: "image/png",
            disposition: .automatic,
            store: nil
        )
    }

    /// Emits a container's children, styling the container to arrange them.
    ///
    /// A container the layout system described as a stack becomes a flex
    /// container, so the browser redoes the arrangement at the reader's width.
    /// One it didn't describe — an overlay, or anything positioning children by
    /// hand — keeps the committed coordinates, since there's no flow rule that
    /// would reproduce them.
    private mutating func emitChildren(
        of container: StaticHTMLBackend.Container,
        style: inout Style,
        indent: String,
        indentLevel: Int,
        stretchesUndeclaredAxis: Bool = false,
        childContentModel: ChildContentModel = .flow
    ) -> String {
        // A wrapper on the way to a raw-fragment leaf carries its own
        // honestly-computed 0x0 committed size (the leaf really was told to
        // be that size, per HTMLRawFragment/HTMLSlot's
        // .frame(width: 0, height: 0)), but that size describes nothing
        // real: the fragment's actual content has no size on the build host
        // at all. Every declaredWidth/declaredMaxWidth/etc. branch below
        // would otherwise turn that 0x0 into a real CSS box — which is
        // exactly what let the spliced content overlap a flex sibling
        // instead of the wrapper participating directly in the parent's
        // layout. display:contents removes the wrapper from layout
        // entirely, so the child (and, transitively, the fragment's real
        // content once the browser parses it) becomes a genuine flex item
        // of whichever ancestor stack this chain sits inside. See
        // ``StaticHTMLBackend/Widget/wrapsRawFragment``.
        if container.wrapsRawFragment {
            style.set("contents", for: "display")
            return emitChildren(
                container.children,
                placement: .flow,
                indent: indent,
                indentLevel: indentLevel,
                childContentModel: childContentModel
            )
        }

        // A size the author asked for is kept whatever else the container
        // turns out to be. Nothing else about a container's geometry survives
        // into the output, so this is the one place a fixed dimension can come
        // from: the author writing one down.
        if let width = container.declaredWidth {
            style.set("\(Int(width))px", for: "width")
        }
        if let height = container.declaredHeight {
            style.set("\(Int(height))px", for: "height")
        }
        // A flexible frame declares a range rather than a fixed size, which
        // CSS min/max-width/height express directly. A *finite* `.infinity`
        // ceiling is CSS's default absent the property, so a finite value is
        // the only one that needs a max-width/max-height declaration at all.
        //
        // `maxWidth: .infinity` (and the height analogue) is a different
        // question from an absent constraint, though: in the SwiftUI dialect
        // it's the "stretch, greedily fill the container" idiom, not "no
        // opinion" — omitting it here would leave the exact author intent
        // this frame exists to carry emitting no CSS at all, content-sizing
        // inside this backend's flex containers (align-items defaults to
        // flex-start/leading, never stretch) exactly like an unframed leaf.
        // See ``HTMLEmitter/applyInfiniteStretch(in:)`` for the mapping.
        if let minWidth = container.declaredMinWidth, minWidth.isFinite {
            style.set("\(Int(minWidth))px", for: "min-width")
        }
        if let maxWidth = container.declaredMaxWidth {
            if maxWidth.isFinite {
                style.set("\(Int(maxWidth))px", for: "max-width")
            } else if maxWidth == .infinity {
                Self.applyInfiniteStretch(in: &style)
            }
        }
        if let minHeight = container.declaredMinHeight, minHeight.isFinite {
            style.set("\(Int(minHeight))px", for: "min-height")
        }
        if let maxHeight = container.declaredMaxHeight {
            if maxHeight.isFinite {
                style.set("\(Int(maxHeight))px", for: "max-height")
            } else if maxHeight == .infinity {
                Self.applyInfiniteStretch(in: &style)
            }
        }

        // A wrapper standing between a stack and a stretching descendant has
        // to carry the same stretch, or the descendant fills only the
        // wrapper's shrink-wrapped box. A `.background()` pair sizes to its
        // foreground, so it relays for the same reason its foreground keeps
        // flow sizing. See
        // ``StaticHTMLBackend/Container/relaysChildStretch``.
        if container.relaysChildStretch
            || (container.isBackgroundLayering && container.containsRelayableStretch)
        {
            Self.applyInfiniteStretch(in: &style)
        }

        // A container whose own declaration leaves this axis open while
        // capping the other at `.infinity` (a hand-built `Color` hairline
        // via `.frame(maxWidth: .infinity, maxHeight:)`, not just a
        // `Divider`) also needs `stretchesUndeclaredAxis`: without it, a
        // leaf on that axis gets its build-host committed size pinned as a
        // min-width floor (below, in the rectangle case), which overflows
        // any narrower render width. A *finite* maxWidth/maxHeight doesn't
        // qualify — that's a real ceiling the pinned size should still floor
        // up to, not a stretch.
        let declaresInfiniteStretch =
            (container.declaredMaxWidth == .infinity && container.declaredWidth == nil)
                || (container.declaredMaxHeight == .infinity && container.declaredHeight == nil)
        let stretchesUndeclaredAxis = stretchesUndeclaredAxis || declaresInfiniteStretch

        guard let stack = container.stackLayout else {
            // A single child inset from every edge is padding, which flow
            // expresses directly. The insets are exactly recoverable: the
            // child's offset gives the leading and top ones, and whatever of
            // the container it doesn't fill gives the other two.
            if container.children.count == 1 {
                let (child, position) = container.children[0]
                let trailing = container.size.x - child.size.x - position.x
                let bottom = container.size.y - child.size.y - position.y
                if position.x >= 0 && position.y >= 0 && trailing >= 0 && bottom >= 0 {
                    // A frame positions its child by alignment rather than by
                    // insetting it, so reading the leftover space as padding
                    // would double the width the author asked for. A flexible
                    // frame does this exactly as a strict one does, even when
                    // it only constrains a range rather than fixing a size.
                    let isFrame =
                        container.declaredWidth != nil || container.declaredHeight != nil
                            || container.declaredMinWidth != nil || container
                            .declaredMaxWidth != nil
                            || container.declaredMinHeight != nil
                            || container.declaredMaxHeight != nil
                    if !isFrame && (position != .zero || trailing != 0 || bottom != 0) {
                        style.set(
                            "\(position.y)px \(trailing)px \(bottom)px \(position.x)px",
                            for: "padding"
                        )
                    }
                    // The wrapper's own width/height (set above from
                    // declaredWidth/declaredHeight) size a normal child fine,
                    // but a void element ignores CSS layout entirely, so it
                    // also gets offered the frame directly; see
                    // ``HTMLEmitter/emit(_:at:placement:indentLevel:inheritedFrame:)``.
                    // Only declaredWidth/declaredHeight carry through — nil
                    // where the frame left that axis alone. Falling back to
                    // the container's own (possibly stretched) committed
                    // size would pin an undeclared axis to whatever room the
                    // layout system happened to give it.
                    let inheritedFrame =
                        isFrame
                            ? InheritedFrame(
                                width: container.declaredWidth.map { Int($0) },
                                height: container.declaredHeight.map { Int($0) }
                            ) : nil
                    // Whether the undeclared axis should stretch to fill
                    // (Divider) rather than floor to committed size
                    // (everything else, including AspectRatioView, whose
                    // undeclared axis carries a meaningful computed value)
                    // isn't decidable from this container alone — it has to
                    // be threaded down from whichever ancestor actually
                    // carried the "Divider" tag. Two separate things are
                    // needed wherever it applies, because they solve
                    // different halves of the problem:
                    //
                    // - align-self:stretch stops *this* wrapper shrink-
                    //   wrapping against *its own* parent's align-items
                    //   (Divider's own align-self:stretch, set at the top of
                    //   ``emit``, only reaches the Divider-tagged widget
                    //   itself — every wrapper below it needs the same
                    //   override against its own immediate parent).
                    // - display:flex, with no explicit align-items (flex's
                    //   real default there is stretch — this backend only
                    //   overrides it for an *explicit* declared
                    //   stackLayout.alignment, which this wrapper doesn't
                    //   have), makes *this* wrapper's own single child fill
                    //   it in turn.
                    //
                    // Together they chain stretch all the way from the
                    // Divider tag down to the leaf with no percentage
                    // cascade to thread through however many wrapper levels
                    // sit in between, and no risk of a shrink-to-fit
                    // ancestor blocking it partway down.
                    if stretchesUndeclaredAxis {
                        style.set("stretch", for: "align-self")
                        // Flexbox's stretch only ever applies on the CROSS
                        // axis, so flex-direction has to put the undeclared
                        // axis there: Divider's usual shape (height declared,
                        // width left to stretch) needs flex-direction:column
                        // so width becomes the cross axis; the perpendicular
                        // case needs row. Leaving flex-direction at its
                        // default (row) stretches the wrong axis entirely: a
                        // block-level child's *height* fills its display:flex
                        // parent while its width, the axis that actually
                        // needs filling, still shrinks to content.
                        if isFrame, inheritedFrame?.width == nil, inheritedFrame?.height != nil {
                            style.set("column", for: "flex-direction")
                            style.set("flex", for: "display")
                        } else if isFrame, inheritedFrame?.height == nil,
                                  inheritedFrame?.width != nil
                        {
                            style.set("row", for: "flex-direction")
                            style.set("flex", for: "display")
                        }
                    }
                    return emitChildren(
                        container.children,
                        placement: .flow,
                        indent: indent,
                        indentLevel: indentLevel,
                        inheritedFrame: inheritedFrame,
                        stretchesUndeclaredAxis: stretchesUndeclaredAxis,
                        childContentModel: childContentModel,
                        parentIsFlex: style.value(for: "display") == "flex"
                    )
                }
            }

            // A .background() pair is a two-child, always-overlapping
            // container by construction (see
            // ``StaticHTMLBackend/Container/isBackgroundLayering``), but it
            // isn't the author declaring overlap the way a ZStack is — the
            // backdrop has no content of its own, so nothing is lost by
            // letting the foreground keep flow sizing (and with it, any
            // declared flexible constraint like .frame(maxWidth:)) while the
            // backdrop stretches to cover whatever box that turns out to be
            // at the reader's width, rather than the generic overlap-pin
            // path baking both to the build host's committed px size.
            if container.isBackgroundLayering, container.children.count == 2 {
                style.set("relative", for: "position")
                // The backdrop is z-index:-1 (see the .backgroundStretch
                // branch in
                // ``HTMLEmitter/emit(_:at:placement:indentLevel:inheritedFrame:stretchesUndeclaredAxis:priorityAllocation:)``),
                // which without a stacking context here would put it behind
                // this wrapper's own ancestors' backgrounds rather than just
                // behind the foreground. isolation rather than z-index:0
                // because it creates the context without also giving this
                // wrapper an explicit paint level among its own siblings,
                // which would reorder the whole subtree against them.
                style.set("isolate", for: "isolation")
                let backdrop = container.children[0].widget
                let foreground = container.children[1].widget
                // Matches the shape ``HTMLEmitter/emitChildren(_:placement:indent:indentLevel:inheritedFrame:stretchesUndeclaredAxis:priorityAllocations:)``
                // produces — a leading newline, each child's markup
                // newline-terminated — since the closing tag this returns
                // into (`isRawInner` branch, back in ``HTMLEmitter/emit(_:at:placement:indentLevel:inheritedFrame:stretchesUndeclaredAxis:priorityAllocation:)``)
                // appends `indent` itself; that helper can't be reused
                // directly because the two children need different
                // placements, not one shared across the list.
                return "\n"
                    + emit(
                        backdrop,
                        at: .zero,
                        placement: .backgroundStretch,
                        indentLevel: indentLevel + 1
                    ) + "\n"
                    + emit(
                        foreground,
                        at: .zero,
                        placement: .flow,
                        indentLevel: indentLevel + 1
                    ) + "\n"
            }

            // Children that overlap can only be described by their
            // coordinates: flow has no rule that would stack them on top of
            // each other. Everything else stays in flow, because a container
            // the author didn't pin shouldn't stop the page reflowing just
            // because this emitter doesn't recognise it.
            guard Self.childrenOverlap(container.children) else {
                return emitChildren(
                    container.children,
                    placement: .flow,
                    indent: indent,
                    indentLevel: indentLevel,
                    childContentModel: childContentModel
                )
            }

            style.set("relative", for: "position")
            style.set(style.value(for: "width") ?? "\(container.size.x)px", for: "width")
            style.set(style.value(for: "height") ?? "\(container.size.y)px", for: "height")
            return emitChildren(
                container.children,
                placement: .absolute,
                indent: indent,
                indentLevel: indentLevel,
                childContentModel: childContentModel
            )
        }

        style.set("flex", for: "display")
        style.set(stack.orientation == .horizontal ? "row" : "column", for: "flex-direction")
        if stack.spacing != 0 && container.children.count > 1 {
            style.set("\(stack.spacing)px", for: "gap")
        }
        // The stack's alignment is across its axis, which is exactly what
        // align-items controls.
        style.set(Self.cssAlignment(stack.alignment), for: "align-items")

        let allocations = Self.priorityAllocations(
            of: container,
            orientation: stack.orientation
        )

        return emitChildren(
            container.children,
            placement: .flow,
            indent: indent,
            indentLevel: indentLevel,
            stretchesUndeclaredAxis: stretchesUndeclaredAxis,
            priorityAllocations: allocations,
            childContentModel: childContentModel,
            parentIsFlex: true
        )
    }

    /// The marker attribute a table's scroll box carries.
    ///
    /// The box is the one element in the document whose content is allowed to
    /// exceed it, so it needs to be findable from outside the interned
    /// classes — see ``documentStylesheet``.
    static let tableScrollMarker = "data-scui-tablescroll"

    /// The rule that keeps a child from widening the page past the viewport.
    ///
    /// Every box in this emitter's output is shrink-to-fit, so content wider
    /// than the space available grows its whole ancestor chain to
    /// `max-content` and takes the document with it: a table needing 1021px
    /// at a 480px viewport took the document's scroll width to 775px with
    /// nothing scrolling anywhere. Capping every element against its
    /// containing block is what stops that, and `min-width:0` is what lets it
    /// apply at all — a flex item's automatic minimum size would otherwise
    /// floor the box at its content.
    ///
    /// This does not forbid horizontal scrolling; it decides where it lives.
    /// A table's scroll box still scrolls, because `overflow-x` only needs
    /// the box to be narrower than its own content — which this cap is what
    /// finally makes true. Deliberate overflow survives; accidental overflow
    /// does not.
    ///
    /// The selector reaches every element rather than just `div`: measured at
    /// 480px, a `div`-scoped form left `<header>`, `<nav>`, and an
    /// author-declared `width:720px` frame overflowing to 744px. Zero
    /// specificity (`:where`), so an interned class or a registered
    /// contribution still outranks it — the same contract the reset holds.
    public var documentStylesheet: String {
        ":where(#root, #root *) { min-width: 0; max-width: 100%; box-sizing: border-box; }"
    }

    /// Which half of a split view a pane is.
    private enum PaneRole {
        case sidebar
        case detail
    }

    /// The sidebar's starting width in a split view's flex row.
    ///
    /// Matches ``StaticHTMLBackend/defaultSidebarWidth``, the width the layout
    /// system was told the sidebar had, so the emitted split lands where the
    /// build host's pass measured the panes against.
    private static let defaultSidebarBasis = 260

    /// The width below which a split view's detail pane wraps beneath the
    /// sidebar instead of staying beside it.
    ///
    /// Narrower than this the pane holds a column too thin to read, so the
    /// stacked layout is the better rendering. This is the value that decides
    /// where the row breaks.
    private static let minimumDetailWidth = 320

    /// Finds the widget an author's `.htmlTag(_:)`/`.htmlAttributes(_:)` on a
    /// pane's root view actually resolved onto.
    ///
    /// `StaticHTMLRenderer.resolveIntent` hoists a request past any
    /// transparent single-child wrapper on its way up the tree, so the
    /// request lands on the innermost real content — several layers below
    /// the plain container ``StaticHTMLBackend/SplitViewWidget/leadingChild``/
    /// ``StaticHTMLBackend/SplitViewWidget/trailingChild`` actually is. This
    /// walks back down the same chain the resolver walked up: as long as a
    /// widget has exactly one child, that child is where a request applied to
    /// this widget's position would have ended up, so it's also where one
    /// meant for the wrapper has to be read from. A widget with zero or
    /// multiple children is a real content boundary — the walk stops there,
    /// same as the resolver's own unwrap rule.
    ///
    /// - Parameter widget: The pane's widget, as received from
    ///   ``StaticHTMLBackend/SplitViewWidget``.
    /// - Returns: The widget carrying whatever request the pane's root view
    ///   declared.
    private static func resolvedPaneOwner(
        _ widget: StaticHTMLBackend.Widget
    ) -> StaticHTMLBackend.Widget {
        var current = widget
        while true {
            let children = current.getChildren()
            guard children.count == 1 else {
                return current
            }
            current = children[0]
        }
    }

    /// Emits one pane of a split view, wrapped in its own landmark element.
    ///
    /// The wrapper is the backend's, not the view's: the pane containers the
    /// core builds are plain containers with no way to say "this one is the
    /// sidebar", and the landmark is exactly that distinction. A reader's
    /// screen reader gets a navigable `<nav>`/`<main>` pair out of it, which is
    /// the accessibility win the static tier is positioned to deliver.
    ///
    /// The wrapper's own element and `aria-label` are reachable through the
    /// same author levers as everywhere else: `.htmlTag(_:)` on the pane's
    /// root view overrides `<nav>`/`<main>` (e.g. demoting a second `<main>`
    /// to `<section>` so a page keeps exactly one), and
    /// `.htmlAttributes(["aria-label": …])` labels the landmark — needed
    /// when a page has more than one `<nav>`, since two unlabelled landmarks
    /// of the same kind aren't distinguishable to assistive tech. Both are
    /// read from wherever ``resolvedPaneOwner(_:)`` says the request actually
    /// landed, and consumed there rather than left to also reach an inner
    /// element the author never asked to tag.
    ///
    /// Any other author attribute on the pane's root view still emits inside
    /// this wrapper, untouched by it.
    ///
    /// - Parameters:
    ///   - pane: The pane's widget.
    ///   - style: The flex sizing for this pane.
    ///   - role: Which half of the split view this is.
    ///   - indentLevel: How far to indent the wrapper.
    /// - Returns: The pane's markup.
    private mutating func emitPane(
        _ pane: StaticHTMLBackend.Widget,
        style: Style,
        role: PaneRole,
        indentLevel: Int
    ) -> String {
        let indent = String(repeating: "  ", count: indentLevel + 1)
        var style = style
        // A pane whose content is taller than the viewport scrolls within
        // itself on a wide screen, which is what makes the two panes read as
        // independent regions. Once they've wrapped to a stacked layout the
        // panes are full-width and the page scrolls instead, so this is scoped
        // to the axis that can actually overflow.
        style.set("auto", for: "overflow-y")

        let requestOwner = Self.resolvedPaneOwner(pane)

        var element = role == .sidebar ? "nav" : "main"
        if let explicit = requestOwner.explicitElement, explicit.isValid {
            element = explicit.name
            requestOwner.explicitElement = nil
        }

        var attributes = ""
        if let className = interner.className(for: style) {
            attributes = " class=\"\(className)\""
        }
        if let ariaLabel = Self.scalarAuthorAttribute(requestOwner.authorAttributes, "aria-label") {
            attributes += " aria-label=\"\(Self.escape(ariaLabel))\""
            requestOwner.authorAttributes["aria-label"] = nil
        }

        let inner = emit(pane, at: .zero, placement: .flow, indentLevel: indentLevel + 1)
        return "\(indent)<\(element)\(attributes)>\n\(inner)\n\(indent)</\(element)>"
    }

    /// Emits a table as real table markup, wrapped in a scroll box.
    ///
    /// The wrapper isn't decoration: a table's column count is fixed by the
    /// data, so a wide one can't reflow the way the rest of this document
    /// does — the columns have a minimum content width below which the only
    /// remaining options are overflowing the viewport or scrolling. An
    /// `overflow-x:auto` box scrolls, keeping the page itself from gaining a
    /// horizontal scrollbar on a phone. `tabindex="0"` comes with it, since a
    /// scrollable region that can't be focused can't be scrolled by keyboard
    /// at all.
    ///
    /// Cells arrive as a flat array in row-major order (see
    /// ``BackendFeatures/Tables/setCells(ofTable:to:withRowHeights:)``), so the
    /// column count is what recovers the rows.
    ///
    /// - Parameters:
    ///   - table: The table to emit.
    ///   - indent: The indentation for the wrapper element.
    ///   - indentLevel: How far the wrapper is indented.
    /// - Returns: The table's markup, wrapper included.
    private mutating func emitTable(
        _ table: StaticHTMLBackend.TableWidget,
        indent: String,
        indentLevel: Int
    ) -> String {
        var wrapperStyle = Style()
        // The box this scrolls is capped against its containing block by
        // ``documentStylesheet``, which is what makes it narrower than a wide
        // table and so lets `overflow-x` engage at all.
        wrapperStyle.set("auto", for: "overflow-x")
        var tableStyle = Style()
        // A table's default `border-collapse` leaves a gap between adjacent
        // cell borders; collapsed is what makes ruling lines meet. width:100%
        // lets the table use the full measure when the columns fit, rather
        // than shrink-wrapping to content and leaving the box short.
        tableStyle.set("collapse", for: "border-collapse")
        tableStyle.set("100%", for: "width")

        let cellIndent = indent + "      "
        let cellAttributes = cellAttributes()
        let headerCellAttributes = headerCellAttributes()
        var rows: [String] = []
        for rowIndex in 0..<table.rowCount {
            var cells: [String] = []
            for columnIndex in 0..<table.columnCount {
                let cellIndex = rowIndex * table.columnCount + columnIndex
                // A row the core hasn't filled in yet has no cells to emit.
                // Emitting an empty `<td>` keeps every row the same width, so
                // the column headers still line up with the data below them.
                let inner =
                    cellIndex < table.cells.count
                        ? "\n"
                        + emit(
                            table.cells[cellIndex],
                            at: .zero,
                            placement: .flow,
                            indentLevel: indentLevel + 3
                        ) + "\n\(cellIndent)"
                        : ""
                cells.append("\(cellIndent)<td\(cellAttributes)>\(inner)</td>")
            }
            let rowIndent = indent + "    "
            rows.append(
                "\(rowIndent)<tr>\n" + cells.joined(separator: "\n") + "\n\(rowIndent)</tr>"
            )
        }

        let headerIndent = indent + "    "
        let headerCells = table.columnLabels
            .map { label in
                // `scope="col"` is what ties a header to the cells beneath it
                // for a screen reader; without it a `<th>` in a `<thead>` is
                // only conventionally a column header, not declaratively one.
                "\(headerIndent)  <th scope=\"col\"\(headerCellAttributes)>"
                    + "\(Self.escape(label))</th>"
            }
            .joined(separator: "\n")

        // `class` and `style` resolve against a backend-owned starting point
        // (the interned table style class; nothing, for `style`) rather than
        // being merged like every other attribute — see the equivalent split
        // in the general widget emission path above.
        var attributes: [String: String] = Self.resolveAuthorAttributes(
            table.authorAttributes.filter { $0.key != "class" && $0.key != "style" },
            internedClass: nil
        )
        if let tag = table.tag, emitsViewIdentity {
            attributes["data-scui"] = tag
        }
        // Absent a `class` op entirely, the interned table class reaches the
        // element unchanged — see the identical distinction in the general
        // widget emission path above (a class op resolving to empty, e.g. a
        // lone `.remove`, is different from no op at all, and must not fall
        // back).
        let internedTableClass = interner.className(for: tableStyle)
        let tableClassName: String?
        if let classOp = table.authorAttributes["class"] {
            tableClassName = Self.resolveAuthorAttributes(
                ["class": classOp],
                internedClass: internedTableClass
            )["class"]
        } else {
            tableClassName = internedTableClass
        }
        if let tableClassName {
            attributes["class"] = tableClassName
        }
        let tableStyleResolution = Self.resolveAuthorAttributes(
            table.authorAttributes.filter { $0.key == "style" },
            internedClass: nil
        )
        if let inlineStyle = tableStyleResolution["style"] {
            attributes["style"] = inlineStyle
        }
        let renderedAttributes =
            attributes
                .sorted { $0.key < $1.key }
                .map { name, value in " \(name)=\"\(Self.escape(value))\"" }
                .joined()

        let sectionIndent = indent + "  "
        var markup = "\(indent)<div\(wrapperAttributes(for: wrapperStyle))>\n"
        markup += "\(sectionIndent)<table\(renderedAttributes)>\n"
        if !table.columnLabels.isEmpty {
            markup += "\(sectionIndent)  <thead>\n"
            markup += "\(headerIndent)<tr>\n\(headerCells)\n\(headerIndent)</tr>\n"
            markup += "\(sectionIndent)  </thead>\n"
        }
        if !rows.isEmpty {
            markup += "\(sectionIndent)  <tbody>\n"
            markup += rows.joined(separator: "\n") + "\n"
            markup += "\(sectionIndent)  </tbody>\n"
        }
        markup += "\(sectionIndent)</table>\n"
        markup += "\(indent)</div>"
        return markup
    }

    /// The attributes for the scroll box a table is wrapped in.
    ///
    /// - Parameter style: The wrapper's style.
    /// - Returns: The rendered attribute string.
    private mutating func wrapperAttributes(for style: Style) -> String {
        var attributes = " \(Self.tableScrollMarker) tabindex=\"0\""
        if let className = interner.className(for: style) {
            attributes = " class=\"\(className)\"" + attributes
        }
        return attributes
    }

    /// The shared styling for a table's data cells.
    ///
    /// Interned like every other style, so all cells in the document share one
    /// class rather than repeating the rule per element.
    private mutating func cellAttributes() -> String {
        var style = Style()
        style.set("left", for: "text-align")
        style.set(
            "\(StaticHTMLBackend.tableCellVerticalPadding)px"
                + " \(StaticHTMLBackend.tableCellHorizontalPadding)px",
            for: "padding"
        )
        guard let className = interner.className(for: style) else {
            return ""
        }
        return " class=\"\(className)\""
    }

    /// The shared styling for a table's header cells.
    ///
    /// - Returns: The rendered attribute string.
    private mutating func headerCellAttributes() -> String {
        var style = Style()
        style.set("left", for: "text-align")
        style.set(
            "\(StaticHTMLBackend.tableCellVerticalPadding)px"
                + " \(StaticHTMLBackend.tableCellHorizontalPadding)px",
            for: "padding"
        )
        style.set("600", for: "font-weight")
        // A header row reads as a header only if it's visually separated from
        // the data; a bottom rule is the lightest way to say so without
        // inventing a color the palette doesn't have.
        style.set("1px solid currentColor", for: "border-bottom")
        guard let className = interner.className(for: style) else {
            return ""
        }
        return " class=\"\(className)\""
    }

    /// Emits a list of children, each on its own line.
    ///
    /// - Parameters:
    ///   - inheritedFrame: A size to offer each child directly, for
    ///     the frame-around-a-void-element case; see
    ///     ``HTMLEmitter/emit(_:at:placement:indentLevel:inheritedFrame:stretchesUndeclaredAxis:)``.
    ///     Only meaningful when `children` holds exactly one widget — a
    ///     frame always wraps a single child — so passing it alongside more
    ///     than one would offer every sibling the same box, which is never
    ///     correct.
    ///   - stretchesUndeclaredAxis: Forwarded to each child's own ``emit``
    ///     call unchanged — this function doesn't interpret it, it only
    ///     relays it past however many non-frame wrapper levels (Divider's
    ///     own stack-layout wrapper, for one) sit between the ancestor that
    ///     set it and the descendant that finally acts on it.
    ///   - priorityAllocations: Each child's layout-priority-derived flex
    ///     declarations, indexed the same way as `children`. `nil` — not an
    ///     all-equal array — is the common case (a stack whose children
    ///     never diverged on ``SwiftCrossUI/View/layoutPriority(_:)``, which
    ///     is most of them): see the call site in
    ///     ``HTMLEmitter/emitChildren(of:style:indent:indentLevel:stretchesUndeclaredAxis:)``.
    ///     An element within the array is `nil` for a child that takes none.
    ///   - parentIsFlex: Whether the element these children are being emitted
    ///     inside is a flex container. Forwarded to each child's own ``emit``
    ///     call, which is where the elision guard reads it.
    private mutating func emitChildren(
        _ children: [(widget: StaticHTMLBackend.Widget, position: SIMD2<Int>)],
        placement: Placement,
        indent: String,
        indentLevel: Int,
        inheritedFrame: InheritedFrame? = nil,
        stretchesUndeclaredAxis: Bool = false,
        priorityAllocations: [PriorityAllocation?]? = nil,
        childContentModel: ChildContentModel = .flow,
        parentIsFlex: Bool = false
    ) -> String {
        guard !children.isEmpty else {
            return ""
        }
        var output = "\n"
        for (offset, element) in children.enumerated() {
            let (childWidget, childPosition) = element
            output += emit(
                childWidget,
                at: childPosition,
                placement: placement,
                indentLevel: indentLevel + 1,
                inheritedFrame: inheritedFrame,
                stretchesUndeclaredAxis: stretchesUndeclaredAxis,
                priorityAllocation: priorityAllocations.flatMap { $0[offset] },
                childContentModel: childContentModel,
                parentIsFlex: parentIsFlex
            )
            output += "\n"
        }
        return output
    }

    /// Gives an element the size the layout system committed for it.
    ///
    /// Only for content the browser can't size on its own. Applying this to
    /// text would be the pinning that keeps the document from reflowing.
    /// Under flow the size is a floor rather than a fixed value, so content
    /// that turns out larger in the browser grows the box instead of spilling
    /// out of it.
    ///
    /// - Parameters:
    ///   - size: The widget's committed size. Used as a fallback floor only
    ///     when `hasEnclosingFrame` is `false` — a bare, unframed leaf has
    ///     nothing else to size itself from.
    ///   - declaredWidth: The width an enclosing frame actually declared for
    ///     this widget, if any. Pinned exactly (`width`, not `min-width`)
    ///     since the author fixed it on purpose.
    ///   - declaredHeight: As `declaredWidth`, for the vertical axis.
    ///   - hasEnclosingFrame: Whether the enclosing wrapper has switched to
    ///     `display:flex` (with flex's own default stretch, no
    ///     `align-items` override) specifically so its cross axis fills
    ///     this widget in — see the `stretchesUndeclaredAxis` handling in
    ///     ``HTMLEmitter/emitChildren(of:style:indent:indentLevel:stretchesUndeclaredAxis:)``.
    ///     Divider is the motivating case: `.frame(height: 1)` declares
    ///     height but leaves width alone on purpose, wanting the browser to
    ///     stretch it to fill — not to float free the way an entirely
    ///     unframed leaf would. `size.x` on that undeclared axis is the
    ///     layout system's stretch-to-fill outcome at this one render
    ///     width, so pinning it (even as a `min-width` floor) would block
    ///     the reflow this stylesheet otherwise promises; leaving the axis
    ///     with no declaration at all lets the ancestor's flex stretch
    ///     size it instead, at every width.
    nonisolated static func pin(
        size: SIMD2<Int>,
        in style: inout Style,
        placement: Placement,
        declaredWidth: Int? = nil,
        declaredHeight: Int? = nil,
        hasEnclosingFrame: Bool = false
    ) {
        guard placement == .flow else {
            // .absolute has already set an exact width and height;
            // .backgroundStretch has already set inset:0, which sizes the
            // element without any width/height declaration of its own.
            return
        }
        if let declaredWidth {
            style.set("\(declaredWidth)px", for: "width")
        } else if !hasEnclosingFrame {
            style.set("\(size.x)px", for: "min-width")
        }
        // hasEnclosingFrame + no declaredWidth: the enclosing wrapper
        // switched to display:flex specifically so its stretch default
        // sizes this axis (see the isFrame branch in
        // ``HTMLEmitter/emitChildren(of:style:indent:indentLevel:stretchesUndeclaredAxis:)``);
        // a min-width floor here would still force overflow at a narrower
        // width even though a bare width never would, so this axis is
        // left with no declaration of its own and inherits the flex
        // stretch entirely.
        if let declaredHeight {
            style.set("\(declaredHeight)px", for: "height")
        } else if !hasEnclosingFrame {
            style.set("\(size.y)px", for: "min-height")
        }
    }

    /// Maps a `.frame(maxWidth: .infinity)` / `.frame(maxHeight: .infinity)`
    /// declaration to the CSS that reproduces its "stretch, greedily fill
    /// the container" meaning.
    ///
    /// The frame doesn't know whether the parent stacked it on the row or
    /// the column axis — that's decided several stack frames up, in
    /// ``HTMLEmitter/emitChildren(of:style:indent:indentLevel:stretchesUndeclaredAxis:)``
    /// for a *different* container than this one — so rather than thread
    /// orientation down just for this case, both possibilities are covered
    /// unconditionally: `align-self:stretch` fills the constrained axis when
    /// it turns out to be the parent stack's cross axis (mirrors the Divider
    /// handling in
    /// ``HTMLEmitter/emit(_:at:placement:indentLevel:inheritedFrame:stretchesUndeclaredAxis:)``),
    /// and `flex-grow`/`flex-shrink`/`flex-basis` fills it when it turns out
    /// to be the main axis instead — `flex-grow` always targets whichever
    /// axis is the parent's main one, so the same declaration is correct
    /// whether that axis happens to be width or height. The two forms don't
    /// interfere with each other: `align-self` only ever affects the cross
    /// axis and `flex-grow` only ever affects the main axis, so a widget
    /// with both `maxWidth: .infinity` and `maxHeight: .infinity` can call
    /// this twice without the second call's flex-grow overwriting anything
    /// the first call meant to keep — both calls want the identical values.
    /// A non-flex parent (plain block flow) already stretches a block-level
    /// child to the container's width by default, so no declaration is
    /// needed there — `align-self` and `flex-grow` are simply ignored
    /// outside a flex container. There's no equivalent free win for height
    /// under block flow (block height is content-driven, not
    /// container-driven), so an infinite maxHeight outside any stack is a
    /// known gap, consistent with this emitter's best-effort contract.
    ///
    /// `flex-grow`/`flex-shrink`/`flex-basis` are only set when nothing
    /// already claimed them: a layout-priority-derived allocation
    /// (``HTMLEmitter/emit(_:at:placement:indentLevel:inheritedFrame:stretchesUndeclaredAxis:priorityAllocation:)``)
    /// can already have written them into this same widget's style before
    /// this function runs, and the author's declared priority is the more
    /// specific signal — an unconditional overwrite here would silently
    /// discard it whenever a stack child happened to carry both
    /// `maxWidth: .infinity` and a non-uniform sibling priority.
    ///
    /// - Parameter style: The declaring widget's own style, mutated in
    ///   place.
    nonisolated static func applyInfiniteStretch(in style: inout Style) {
        style.set("stretch", for: "align-self")
        if style.value(for: "flex-grow") == nil {
            style.set("1", for: "flex-grow")
        }
        if style.value(for: "flex-shrink") == nil {
            style.set("1", for: "flex-shrink")
        }
        if style.value(for: "flex-basis") == nil {
            style.set("0%", for: "flex-basis")
        }
    }

    /// Maps a stack child's ``SwiftCrossUI/View/layoutPriority(_:)`` to a
    /// `flex-shrink` weight, relative to the highest priority among its
    /// siblings.
    ///
    /// The layout system's own algorithm (``LayoutSystem/computeLayouts``)
    /// isn't proportional — it processes children in strict descending-
    /// priority order, letting the highest-priority group claim all the
    /// space it wants before a lower one sees any leftovers — and
    /// `flex-shrink` has no way to reach that ordering: shrinkage spreads
    /// proportionally across every weight at once, never exhausting one
    /// tier before touching the next. The grow side does reach it, by a
    /// route with no shrink-side counterpart — a max-violated item releases
    /// its unused space to the items still growing, which
    /// ``flexGrowWeight(priority:relativeToMin:)`` turns into hand-down
    /// ordering. This is the nearest proportional approximation of that
    /// reproduction of it: each whole point of priority below the group
    /// maximum doubles shrink resistance relative to the top group, so the
    /// highest-priority children give up the least space and lower-priority
    /// ones give up correspondingly more as the row is squeezed — the same
    /// direction of effect the real algorithm produces, even though the
    /// exact split will differ from an author who profiled against
    /// SwiftUI's own layout.
    ///
    /// - Parameters:
    ///   - priority: This child's own layout priority.
    ///   - maxPriority: The highest priority among this child's stack
    ///     siblings (including itself).
    /// - Returns: A `flex-shrink` weight. Always positive: an author who set
    ///   a *lower-than-everyone-else* priority still gets a proportionally
    ///   large but finite weight, never zero, so that child still shrinks
    ///   rather than becoming perfectly rigid at the wrong end of the
    ///   priority scale.
    nonisolated static func flexShrinkWeight(
        priority: Double,
        relativeToMax maxPriority: Double
    ) -> Double {
        // An unbounded gap — a Spacer's -infinity priority against a finite
        // sibling maximum, or two -infinity spacers measured against each
        // other — would make `2^(maxPriority - priority)` infinite or NaN.
        // Clamping to the ends of the representable span keeps this total
        // for every input, including the -infinity minus -infinity that is
        // NaN before the clamp sees it.
        let delta = (maxPriority - priority).isNaN
            ? 0 : min(max(maxPriority - priority, 0), 32)
        return pow(2, delta)
    }

    /// Maps a stack child's ``SwiftCrossUI/View/layoutPriority(_:)`` to a
    /// `flex-grow` weight, relative to the lowest priority among its
    /// siblings.
    ///
    /// Unlike the shrink side, this reproduces the layout system's
    /// descending-priority ordering rather than approximating it, as long as
    /// each child also carries its own flexibility endpoints as `min-`/
    /// `max-width` (or the height family, in a column). CSS grows every item
    /// with a positive weight simultaneously, but an item that hits its
    /// maximum freezes there and its unused share is redistributed among the
    /// items still growing. A weight ratio this steep makes a higher tier
    /// absorb effectively all surplus until its maximum freezes it, at which
    /// point the remainder falls to the tier below — which is what claiming
    /// space in priority order means.
    ///
    /// The steepness is load-bearing in both directions. Weights within an
    /// order of magnitude of each other split surplus visibly rather than
    /// handing it down; a lower tier weighted at zero (or near enough that
    /// it rounds to zero) never receives the frozen tier's release at all
    /// and the stack simply stops growing.
    ///
    /// - Parameters:
    ///   - priority: This child's own layout priority.
    ///   - minPriority: The lowest priority among this child's stack
    ///     siblings (including itself).
    /// - Returns: A `flex-grow` weight, always at least 1.
    nonisolated static func flexGrowWeight(
        priority: Double,
        relativeToMin minPriority: Double
    ) -> Double {
        // Four points of separation is already past the width of any layout
        // this can be asked about, and the clamp is what keeps the result a
        // finite double for an author who wrote a priority in the thousands.
        // The lower clamp covers the unbounded gaps: a Spacer's -infinity
        // priority against a finite minimum, and the -infinity minus
        // -infinity that is NaN before any comparison sees it.
        let delta = (priority - minPriority).isNaN
            ? 0 : min(max(priority - minPriority, 0), 4)
        return pow(1e6, delta)
    }

    /// The priority-derived flex declarations for one stack child.
    public struct PriorityAllocation: Equatable, Sendable {
        /// Resistance to giving up space, from
        /// ``HTMLEmitter/flexShrinkWeight(priority:relativeToMax:)``.
        public var shrink: Double
        /// Claim on surplus space, from
        /// ``HTMLEmitter/flexGrowWeight(priority:relativeToMin:)``. `nil`
        /// when the child's flexibility endpoints never reached the backend,
        /// which is what the grow construction needs to bound its tiers.
        public var grow: Double?
        /// The child's size at a zero proposal, and at an infinite one.
        /// Emitted as the min/max pair on the stack's axis, giving the
        /// growth weights the clamps they hand surplus down at.
        public var minimum: Double?
        public var maximum: Double?
        /// The axis the stack distributes space along, which decides whether
        /// the clamps are written as widths or heights.
        public var orientation: Orientation
    }

    /// Derives each stack child's priority-driven flex declarations.
    ///
    /// Returns `nil` when every ranked child shares one priority — the
    /// common case, and what an author who never touched
    /// ``SwiftCrossUI/View/layoutPriority(_:)`` gets. There is nothing for
    /// the weights to modulate, and emitting them would only restate
    /// flexbox's own defaults. A stack whose only priority spread comes from
    /// a Spacer lands here too, leaving both the Spacer and its siblings on
    /// the declarations they emit outside this path.
    ///
    /// - Parameters:
    ///   - container: The container being emitted as a flex stack.
    ///   - orientation: The axis the stack distributes space along.
    /// - Returns: One allocation per child, indexed as `container.children`.
    ///   `nil` at a child that takes no priority-derived declarations.
    nonisolated static func priorityAllocations(
        of container: StaticHTMLBackend.Container,
        orientation: Orientation
    ) -> [PriorityAllocation?]? {
        guard let priorities = container.childLayoutPriorities else {
            return nil
        }

        // Spacers are excluded from the span the weights are measured
        // against as well as from the output: -infinity as a group minimum
        // would put every real child at the top of a range no author wrote,
        // flattening the tiers that separate them from each other.
        let ranked = zip(priorities, container.children)
            .filter { !isSpacer($0.1.widget) }
            .map(\.0)
        guard let maxPriority = ranked.max(),
              let minPriority = ranked.min(),
              minPriority != maxPriority
        else {
            return nil
        }

        // The endpoints are reported for the stack as a whole or not at all,
        // and their absence only costs the grow side: shrink weights are a
        // function of priority alone.
        let flexibility = container.childFlexibility.flatMap {
            $0.minimums.count == priorities.count && $0.maximums.count == priorities.count
                ? $0 : nil
        }

        return priorities.enumerated().map { index, priority -> PriorityAllocation? in
            // A Spacer carries no allocation, so its own emitter case keeps
            // the `flex:1 1 0%` that expresses "take the leftovers, yield
            // first". Weights derived from its -infinity priority would
            // describe the opposite: the declarations here are longhands,
            // and every one of them sorts after `flex` in the emitted rule,
            // so they would override that shorthand rather than refine it.
            guard !isSpacer(container.children[index].widget) else {
                return nil
            }
            return PriorityAllocation(
                shrink: flexShrinkWeight(priority: priority, relativeToMax: maxPriority),
                grow: flexibility.map { _ in
                    flexGrowWeight(priority: priority, relativeToMin: minPriority)
                },
                minimum: flexibility?.minimums[index],
                maximum: flexibility?.maximums[index],
                orientation: orientation
            )
        }
    }

    /// Whether a stack child is a ``SwiftCrossUI/Spacer``.
    ///
    /// Spacer has no dedicated Widget subclass — it's a plain empty
    /// Container marked by ``BackendFeatures/Widgets/describeSpacer(of:)``,
    /// so the marker is the only thing that identifies one.
    nonisolated static func isSpacer(_ widget: StaticHTMLBackend.Widget) -> Bool {
        (widget as? StaticHTMLBackend.Container)?.isSpacer == true
    }

    /// Whether any two of a container's children share area.
    ///
    /// Overlap is the one arrangement flow has no rule for, so it's what
    /// decides that a container has to keep its committed coordinates.
    nonisolated static func childrenOverlap(
        _ children: [(widget: StaticHTMLBackend.Widget, position: SIMD2<Int>)]
    ) -> Bool {
        for first in children.indices {
            for second in children.indices where second > first {
                let a = children[first]
                let b = children[second]
                let horizontal =
                    min(a.position.x + a.widget.size.x, b.position.x + b.widget.size.x)
                        - max(a.position.x, b.position.x)
                let vertical =
                    min(a.position.y + a.widget.size.y, b.position.y + b.widget.size.y)
                        - max(a.position.y, b.position.y)
                if horizontal > 0 && vertical > 0 {
                    return true
                }
            }
        }
        return false
    }

    /// Maps a stack's cross-axis alignment to its CSS equivalent.
    ///
    /// A custom guide resolves per-child against geometry only SwiftCrossUI can
    /// evaluate, and CSS has no channel for that, so it degrades to whichever
    /// edge its line sits nearest — an approximation the static tier accepts.
    nonisolated static func cssAlignment(_ alignment: StackAlignmentDescription) -> String {
        switch alignment.closestEdge {
            case .leading: "flex-start"
            case .center: "center"
            case .trailing: "flex-end"
        }
    }

    /// Maps a declared multiline text alignment to its CSS equivalent.
    ///
    /// Text justification only has the three edge spellings, so a custom
    /// alignment guide justifies as leading.
    nonisolated static func cssTextAlign(_ alignment: HorizontalAlignment) -> String {
        switch alignment.asEdge {
            case .center: "center"
            case .trailing: "right"
            case .leading, nil: "left"
        }
    }

    /// Resolves author attribute operations to their final string values,
    /// applying a `class` op against the backend's own class-list starting
    /// point rather than overwriting it. `style` op resolution starts from
    /// nothing, since this backend never writes `style` itself — its own
    /// styling always goes through interned classes.
    ///
    /// Every other key resolves independently of what the backend does with
    /// it — a scalar `.set` produces its string outright; a token-list
    /// `.add`/`.remove`/`.replace` on some other token-list attribute (e.g.
    /// `aria-labelledby`) starts from an empty token list, since the backend
    /// doesn't pre-populate those. Backend-derived values for the same key
    /// (`id`, `aria-labelledby` from a label association, `data-scui`, …)
    /// are applied by the caller afterward and win regardless — see the
    /// merge order at each call site.
    ///
    /// A `class` key with no matching op in `authorAttributes` produces no
    /// entry here at all — callers that need `internedClass` to still reach
    /// the element when the author supplied no `class` op handle that
    /// fallback themselves, since only the caller knows whether an op was
    /// actually present (an op that resolves to an empty token list, e.g. a
    /// lone `.remove` of the only class, is a real "no class" outcome and
    /// must not fall back).
    ///
    /// - Parameters:
    ///   - authorAttributes: The merged author attribute operations for one
    ///     element.
    ///   - internedClass: The class name the backend interned for this
    ///     element's own styling, if any — the starting token a `class` op
    ///     applies against.
    /// - Returns: Resolved scalar values, keyed by attribute name. Empty
    ///   token lists and empty `style` bodies are omitted rather than
    ///   emitted as empty strings.
    nonisolated static func resolveAuthorAttributes(
        _ authorAttributes: [String: HTMLAttributeOp],
        internedClass: String?
    ) -> [String: String] {
        var resolved: [String: String] = [:]
        for (name, op) in authorAttributes where HTMLElement.isValidName(name) {
            switch op {
                case .set(let value):
                    resolved[name] = value
                case .add, .remove, .replace:
                    var tokens =
                        name == "class"
                            ? (internedClass.map { [$0] } ?? [])
                            : []
                    apply(op, toTokens: &tokens)
                    if !tokens.isEmpty {
                        resolved[name] = tokens.joined(separator: " ")
                    }
                case .setProperty, .removeProperty:
                    var style = Style()
                    apply(op, toStyle: &style)
                    if !style.isEmpty {
                        resolved[name] = style.cssBody
                    }
            }
        }
        return resolved
    }

    /// Applies a token-list operation (`.add`/`.remove`/`.replace`) to a
    /// token list, in place. Any other case is a no-op — callers only pass
    /// the three token-list cases.
    private nonisolated static func apply(_ op: HTMLAttributeOp, toTokens tokens: inout [String]) {
        switch op {
            case .add(let token):
                if !tokens.contains(token) {
                    tokens.append(token)
                }
            case .remove(let token):
                tokens.removeAll { $0 == token }
            case .replace(let token, let replacement):
                if let index = tokens.firstIndex(of: token) {
                    tokens[index] = replacement
                }
            case .set, .setProperty, .removeProperty:
                break
        }
    }

    /// Applies a property-map operation (`.setProperty`/`.removeProperty`)
    /// to a style, in place. Any other case is a no-op — callers only pass
    /// the two property-map cases.
    private nonisolated static func apply(_ op: HTMLAttributeOp, toStyle style: inout Style) {
        switch op {
            case .setProperty(let property, let value):
                style.set(value, for: property)
            case .removeProperty(let property):
                style.set(nil, for: property)
            case .set, .add, .remove, .replace:
                break
        }
    }

    /// Reads the scalar string an author attribute op resolves to, for the
    /// few read sites that need to inspect one author-supplied value
    /// directly (e.g. checking whether `role` or `alt` was author-set)
    /// rather than emitting the whole set.
    ///
    /// Only `.set` (including the `ExpressibleByStringLiteral` shorthand)
    /// has a single scalar value; every other case describes an edit against
    /// a starting point this accessor doesn't have, so it returns `nil`
    /// rather than guessing.
    ///
    /// - Parameters:
    ///   - authorAttributes: The widget's merged author attribute operations.
    ///   - name: The attribute name to read.
    /// - Returns: The scalar value, if the author set one with `.set`.
    nonisolated static func scalarAuthorAttribute(
        _ authorAttributes: [String: HTMLAttributeOp],
        _ name: String
    ) -> String? {
        guard case .set(let value) = authorAttributes[name] else {
            return nil
        }
        return value
    }

    /// Element names that support the native `disabled` attribute.
    ///
    /// `<a>` doesn't — its disabled semantics come from omitting `href`
    /// instead, handled separately above — so it's excluded here to avoid
    /// emitting an attribute the HTML spec doesn't define for it.
    nonisolated static let disablableElementNames: Set<String> = ["button", "input"]

    /// Converts a linear gradient's two unit points into a CSS angle.
    ///
    /// CSS measures the angle clockwise from "to top"; the points are in the
    /// view's y-down space, where the same direction is a negative y delta.
    ///
    /// - Parameters:
    ///   - start: The point the gradient starts at.
    ///   - end: The point the gradient ends at.
    /// - Returns: The gradient's direction, in degrees.
    nonisolated static func gradientAngle(from start: UnitPoint, to end: UnitPoint) -> Double {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        guard deltaX != 0 || deltaY != 0 else {
            return 180
        }
        let degrees = atan2(deltaX, -deltaY) * 180 / .pi
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        return normalized < 0 ? normalized + 360 : normalized
    }

    /// Whether a color paints anything under either scheme.
    ///
    /// - Parameter pair: The color to check.
    /// - Returns: Whether the color is visible in at least one scheme.
    nonisolated static func isVisible(_ pair: SchemePair) -> Bool {
        pair.light.opacity > 0 || pair.dark.opacity > 0
    }

    /// Maps a stroke cap to its SVG `stroke-linecap` keyword.
    ///
    /// - Parameter cap: The cap to map.
    /// - Returns: The corresponding SVG keyword.
    nonisolated static func cssLineCap(_ cap: StrokeCap) -> String {
        switch cap {
            case .butt: "butt"
            case .round: "round"
            case .square: "square"
        }
    }

    /// Maps a stroke join to its SVG `stroke-linejoin` keyword.
    ///
    /// - Parameter join: The join to map.
    /// - Returns: The corresponding SVG keyword.
    nonisolated static func cssLineJoin(_ join: StrokeJoin) -> String {
        switch join {
            case .miter: "miter"
            case .round: "round"
            case .bevel: "bevel"
        }
    }

    /// Formats a `Double` the way a numeric HTML attribute expects: no
    /// trailing `.0` for whole numbers, since `min`/`max`/`value` on
    /// `<input type=range>` are otherwise indistinguishable from an author
    /// having actually asked for a fractional bound.
    nonisolated static func formatNumber(_ value: Double) -> String {
        guard let exact = Int(exactly: value.rounded()), value == value.rounded() else {
            // A magnitude past Int's range has no integer spelling to fall
            // back to; Double's own description stays valid CSS.
            return String(value)
        }
        return String(exact)
    }

    /// Recovers the text style a declared font names, if it names one plainly.
    ///
    /// ``Font/Resolved`` keeps no record of where its metrics came from, so
    /// the only thing that can say "this element is Body" is the un-resolved
    /// font the author declared. A font is attributable when it's equal to one
    /// of the bare text-style constants.
    ///
    /// **A font carrying any modifier is deliberately not attributable.**
    /// `.font(.body.weight(.black))`, `.italic()`, and `.scaled(by:)` all
    /// compare unequal to `.body`, so they fall through to literal pixel
    /// values instead of riding the type scale's custom properties. That's the
    /// designed behaviour, not an oversight: a modified font's metrics are the
    /// author's arithmetic on top of a style, and the responsive tables have
    /// no entry that reproduces them — publishing it as `var(--scui-fs-body)`
    /// would silently discard the modifier at every width. Explicit-size fonts
    /// (`Font.system(size: 13)`) are excluded by the same rule, which is what
    /// keeps them literal.
    ///
    /// Widening this to cover modified fonts would mean decomposing a `Font`
    /// into style-plus-overlay, which needs `@_spi(Backends)` access the type
    /// doesn't currently offer.
    ///
    /// - Parameter font: The un-resolved font the author declared.
    /// - Returns: The text style, or `nil` if the font isn't a bare style.
    nonisolated static func textStyle(for font: Font?) -> Font.TextStyle? {
        guard let font else {
            return nil
        }
        return Self.bareTextStyleFonts[font]
    }

    /// Every bare text-style constant, keyed by the font itself.
    ///
    /// Built from ``SwiftCrossUI/Font/TextStyle/allCases`` so a text style
    /// added upstream can't quietly go unattributed here.
    private nonisolated static let bareTextStyleFonts: [Font: Font.TextStyle] = {
        var fonts: [Font: Font.TextStyle] = [:]
        for style in Font.TextStyle.allCases {
            fonts[Font.system(style)] = style
        }
        return fonts
    }()

    /// Maps a resolved font weight to its CSS numeric equivalent.
    nonisolated static func cssWeight(_ weight: Font.Weight) -> String {
        switch weight {
            case .ultraLight: "100"
            case .thin: "200"
            case .light: "300"
            case .regular: "400"
            case .medium: "500"
            case .semibold: "600"
            case .bold: "700"
            case .heavy: "800"
            case .black: "900"
        }
    }

    /// The text of a button label that is nothing but an unstyled run of
    /// characters, or `nil` where the label needs its subtree emitted.
    ///
    /// `Button("Press")` expands to a `Text` under whatever wrappers the view
    /// builder produced, and putting the characters straight inside the
    /// control keeps that case free of elements standing for nothing. The test
    /// is deliberately strict — any styling, attribute, tag, href or sibling
    /// disqualifies the label, because a wrapper carrying one of those is
    /// carrying something the reader would lose.
    ///
    /// - Parameter label: The button's label widget.
    /// - Returns: The text to place inside the control, or `nil`.
    private static func plainTextLabel(of label: StaticHTMLBackend.Widget) -> String? {
        var current = label
        while true {
            guard current.carriesNoAuthoredIntent else {
                return nil
            }
            if let text = current as? StaticHTMLBackend.TextView {
                // A styled run has to keep the span that carries the style.
                // `.body` is the environment's default rather than a declared
                // font, and the control inherits it either way, so a label
                // carrying it is still an unstyled one.
                guard
                    text.declaredFont == .body, !text.hasDeclaredColor, text.lineLimit == nil,
                    !text.isTextSelectionEnabled, text.textAlignment == .leading
                else {
                    return nil
                }
                return text.content
            }
            let children = current.getChildren()
            guard children.count == 1 else {
                return nil
            }
            current = children[0]
        }
    }

    /// Escapes a string for inclusion in markup or an attribute value.
    ///
    /// - Parameter string: The string to escape.
    /// - Returns: The escaped string.
    public nonisolated static func escape(_ string: String) -> String {
        var output = ""
        output.reserveCapacity(string.count)
        for character in string {
            switch character {
                case "&": output += "&amp;"
                case "<": output += "&lt;"
                case ">": output += "&gt;"
                case "\"": output += "&quot;"
                case "'": output += "&#39;"
                default: output.append(character)
            }
        }
        return output
    }
}
