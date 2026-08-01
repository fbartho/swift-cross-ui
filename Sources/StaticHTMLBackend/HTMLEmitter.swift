import Foundation
import ImageFormats
@_spi(Backends) import SwiftCrossUI

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

    /// How a parent is positioning one of its children.
    public enum Placement: Hashable, Sendable {
        /// The browser places the element, which is the usual case. The
        /// element's size comes from its content and from whatever the parent's
        /// flow rules impose.
        case flow
        /// The element is pinned to the coordinates the layout system committed
        /// for it. Used only where flow can't express the arrangement.
        case absolute
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
    ///     levels below whichever ancestor actually carried the "Divider"
    ///     tag — see the widget.tag == "Divider" check at the top of this
    ///     function, and the matching flex/align-self handling in
    ///     ``HTMLEmitter/emitChildren(of:style:indent:indentLevel:stretchesUndeclaredAxis:)``.
    ///   - flexShrinkWeight: A layout-priority-derived shrink resistance for
    ///     this widget specifically, when it's a direct child of a stack
    ///     whose children didn't all share the same
    ///     ``SwiftCrossUI/View/layoutPriority(_:)``. See
    ///     ``HTMLEmitter/flexShrinkWeight(priority:relativeToMax:)``.
    /// - Returns: The widget's markup.
    public mutating func emit(
        _ widget: StaticHTMLBackend.Widget,
        at origin: SIMD2<Int>,
        placement: Placement = .flow,
        indentLevel: Int = 0,
        inheritedFrame: InheritedFrame? = nil,
        stretchesUndeclaredAxis: Bool = false,
        flexShrinkWeight: Double? = nil
    ) -> String {
        let indent = String(repeating: "  ", count: indentLevel + 1)

        var style = Style()
        if let flexShrinkWeight {
            // flex-basis:auto (the default) keeps the child's own natural/
            // committed size as its starting point before shrinking — the
            // same "committed size is the reflow starting point" principle
            // this emitter already applies elsewhere (Rectangle's fallback,
            // for one) — so only flex-shrink needs setting here; a bare
            // flex-shrink declaration doesn't imply flex-basis:0% the way
            // the `flex` shorthand would.
            style.set("\(Self.formatNumber(flexShrinkWeight))", for: "flex-shrink")
        }
        if placement == .absolute {
            style.set("absolute", for: "position")
            style.set("\(origin.x)px", for: "left")
            style.set("\(origin.y)px", for: "top")
            style.set("\(widget.size.x)px", for: "width")
            style.set("\(widget.size.y)px", for: "height")
        }
        if widget.cornerRadius > 0 {
            style.set("\(widget.cornerRadius)px", for: "border-radius")
        }
        if widget.tag == "Divider" {
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
        // Attributes a control case needs beyond what every widget already
        // gets (role, data-scui, class, ...) — checked/value/min/max/etc.
        // Kept separate from `attributes` below so author attributes are
        // still merged first and can't be clobbered by a backend-owned one.
        var controlAttributes: [String: String] = [:]

        switch widget {
            case let text as StaticHTMLBackend.TextView:
                element = .span
                if let font = text.font {
                    style.set("\(Int(font.pointSize))px", for: "font-size")
                    style.set("\(Int(font.lineHeight))px", for: "line-height")
                    style.set(Self.cssWeight(font.weight), for: "font-weight")
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
                // for, so it outranks the generic span.
                if let derived = headingMap.element(for: text.declaredFont) {
                    element = derived
                }

            case let button as StaticHTMLBackend.Button:
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
                // View layer and on the widget (`StaticHTMLBackend.Button`
                // doesn't even retain the closure — see `updateButton`).
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
                style.set("inline-flex", for: "display")
                style.set("center", for: "align-items")
                style.set("center", for: "justify-content")
                style.set("none", for: "text-decoration")
                style.set("border-box", for: "box-sizing")
                inner = Self.escape(button.label)

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
                // flex stretch entirely. A Rectangle reached through
                // .aspectRatio(), by contrast, has a *meaningful* committed
                // value on its undeclared axis — the proportional height
                // the ratio computed — so it stays a floor like any other
                // unframed leaf; treating it as a flex-stretch target would
                // silently discard the ratio.
                Self.pin(
                    size: rectangle.size,
                    in: &style,
                    placement: placement,
                    declaredWidth: inheritedFrame?.width,
                    declaredHeight: inheritedFrame?.height,
                    hasEnclosingFrame: stretchesUndeclaredAxis
                )

            case let image as StaticHTMLBackend.ImageView:
                // <img> is a void element, so it's the one place a data URL
                // can carry the picture itself rather than a path to it: the
                // static tier has no server to host a separate file against.
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
                        controlAttributes["src"] =
                            "data:image/png;base64,\(Data(png).base64EncodedString())"
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
                // out of a missing attribute.
                controlAttributes["alt"] = image.authorAttributes["alt"] ?? ""
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

            case let container as StaticHTMLBackend.Container where container.tag == "Spacer":
                // Spacer has no dedicated Widget subclass of its own — it's a
                // plain empty Container — so the view-type tag the core
                // already stamps on every widget (see ViewGraphNode.init) is
                // the only signal available to recognise it here. Its
                // layoutPriority(-infinity) preference, which is what tells
                // the layout system to shrink it first, is consumed entirely
                // inside LayoutSystem and never reaches the backend, so
                // there's no geometry-based way to infer "this is a spacer"
                // after the fact. flex:1 1 0% reproduces the same
                // greedy-but-shrinkable behaviour in the flex model: it grows
                // to fill leftover space and yields before any sibling with a
                // real minimum content size would be squeezed.
                style.set("1 1 0%", for: "flex")

            case let container as StaticHTMLBackend.Container:
                // The stretch signal outlives whichever ancestor actually
                // carried the "Divider" tag: Divider composes as
                // `Divider(Container) → StrictFrameView(Container) →
                // Color(Rectangle)`, so a wrapper two levels down from the
                // tag still needs to know it's inside a Divider when it
                // constructs its own InheritedFrame for its single child.
                // widget.tag == "Divider" starts the signal; the incoming
                // stretchesUndeclaredAxis parameter (already threaded down
                // by an ancestor's own emit call) keeps it alive past that
                // point.
                inner = emitChildren(
                    of: container,
                    style: &style,
                    indent: indent,
                    indentLevel: indentLevel,
                    stretchesUndeclaredAxis: widget.tag == "Divider" || stretchesUndeclaredAxis
                )
                isRawInner = true

            case let scroll as StaticHTMLBackend.ScrollContainer:
                style.set("auto", for: "overflow")
                Self.pin(size: scroll.size, in: &style, placement: placement)
                inner = emitChildren(
                    [(scroll.child, .zero)],
                    placement: .flow,
                    indent: indent,
                    indentLevel: indentLevel
                )
                isRawInner = true

            default:
                let children = widget.getChildren()
                if !children.isEmpty {
                    inner = emitChildren(
                        children.map { ($0, SIMD2<Int>.zero) },
                        placement: .flow,
                        indent: indent,
                        indentLevel: indentLevel
                    )
                    isRawInner = true
                }
        }

        // An explicit tag is the author overriding everything above.
        if let explicit = widget.explicitElement, explicit.isValid {
            element = explicit
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

        var attributes: [String: String] = [:]
        // Author attributes are merged first so that backend-owned ones
        // overwrite them rather than the other way around.
        for (name, value) in widget.authorAttributes
            where HTMLElement.isValidName(name) && !Self.reservedAttributes.contains(name)
        {
            attributes[name] = value
        }
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
        if let tag = widget.tag {
            attributes["data-scui"] = tag
        }
        if let className = interner.className(for: style) {
            attributes["class"] = className
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
        stretchesUndeclaredAxis: Bool = false
    ) -> String {
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
                    // where the frame left that axis alone, never falling
                    // back to the container's own (possibly stretched)
                    // committed size, which is what used to pin an
                    // undeclared axis to whatever room the layout system
                    // happened to give it.
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
                        // default (row) here — as an earlier version of this
                        // fix did — stretched the wrong axis entirely: a
                        // block-level child's *height* filled its
                        // display:flex parent while its width, the axis
                        // that actually needed filling, still shrank to
                        // content.
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
                        stretchesUndeclaredAxis: stretchesUndeclaredAxis
                    )
                }
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
                    indentLevel: indentLevel
                )
            }

            style.set("relative", for: "position")
            style.set(style.value(for: "width") ?? "\(container.size.x)px", for: "width")
            style.set(style.value(for: "height") ?? "\(container.size.y)px", for: "height")
            return emitChildren(
                container.children,
                placement: .absolute,
                indent: indent,
                indentLevel: indentLevel
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

        // layoutPriority reaches the layout system as a strict ordering
        // (the highest-priority group claims space first; a lower one only
        // gets leftovers), which flex-shrink can't reproduce exactly — CSS
        // only ever redistributes proportionally. Per-child flex-shrink
        // weighted by relative priority is the nearest proportional
        // approximation, and it's skipped entirely when every child shares
        // one priority (the common case, and what an author who never
        // touched layoutPriority gets): there's nothing for it to modulate,
        // and it would just be redundant with flexbox's own default.
        let flexShrinkWeights: [Double]? = container.childLayoutPriorities.flatMap { priorities in
            guard let maxPriority = priorities.max(), priorities.min() != maxPriority else {
                return nil
            }
            return priorities
                .map { Self.flexShrinkWeight(priority: $0, relativeToMax: maxPriority) }
        }

        return emitChildren(
            container.children,
            placement: .flow,
            indent: indent,
            indentLevel: indentLevel,
            stretchesUndeclaredAxis: stretchesUndeclaredAxis,
            flexShrinkWeights: flexShrinkWeights
        )
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
    ///   - flexShrinkWeights: Each child's layout-priority-derived shrink
    ///     resistance, indexed the same way as `children`. `nil` — not an
    ///     all-equal array — is the common case (a stack whose children
    ///     never diverged on ``SwiftCrossUI/View/layoutPriority(_:)``, which
    ///     is most of them): see the call site in
    ///     ``HTMLEmitter/emitChildren(of:style:indent:indentLevel:stretchesUndeclaredAxis:)``.
    private mutating func emitChildren(
        _ children: [(widget: StaticHTMLBackend.Widget, position: SIMD2<Int>)],
        placement: Placement,
        indent: String,
        indentLevel: Int,
        inheritedFrame: InheritedFrame? = nil,
        stretchesUndeclaredAxis: Bool = false,
        flexShrinkWeights: [Double]? = nil
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
                flexShrinkWeight: flexShrinkWeights?[offset]
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
            // The absolute branch has already set an exact width and height.
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
    /// `flex-shrink`/`flex-basis` are only set when nothing already claimed
    /// them: a layout-priority-derived shrink weight
    /// (``HTMLEmitter/emit(_:at:placement:indentLevel:inheritedFrame:stretchesUndeclaredAxis:flexShrinkWeight:)``)
    /// can already have written `flex-shrink` into this same widget's style
    /// before this function runs, and the author's declared priority is the
    /// more specific signal — an unconditional overwrite here would
    /// silently discard it whenever a stack child happened to carry both
    /// `maxWidth: .infinity` and a non-uniform sibling priority.
    ///
    /// - Parameter style: The declaring widget's own style, mutated in
    ///   place.
    nonisolated static func applyInfiniteStretch(in style: inout Style) {
        style.set("stretch", for: "align-self")
        style.set("1", for: "flex-grow")
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
    /// space it wants before a lower one sees any leftovers — and CSS
    /// flex-shrink has no equivalent strict-ordering mode; it only ever
    /// redistributes shrinkage proportionally to each item's weight. This is
    /// the nearest proportional approximation of that ordering, not a
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
        // -infinity (Spacer's own layoutPriority, though Spacer is handled
        // by its own emitter case before reaching here — see the tag ==
        // "Spacer" branch in ``HTMLEmitter/emit(_:at:placement:indentLevel:inheritedFrame:stretchesUndeclaredAxis:flexShrinkWeight:)``)
        // would make `2^(maxPriority - priority)` infinite; clamping the
        // exponent keeps this total function for any input a future caller
        // might pass, rather than relying on that other case to always
        // intercept it first.
        let delta = min(maxPriority - priority, 32)
        return pow(2, delta)
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
    nonisolated static func cssAlignment(_ alignment: StackAlignment) -> String {
        switch alignment {
            case .leading: "flex-start"
            case .center: "center"
            case .trailing: "flex-end"
        }
    }

    /// Maps a declared multiline text alignment to its CSS equivalent.
    nonisolated static func cssTextAlign(_ alignment: HorizontalAlignment) -> String {
        switch alignment {
            case .leading: "left"
            case .center: "center"
            case .trailing: "right"
        }
    }

    /// Attributes that the backend owns and authors may not overwrite.
    ///
    /// `style` is absent from the emitted markup entirely (styling goes
    /// through interned classes), so letting an author set it would reintroduce
    /// exactly the inline styling this backend avoids.
    nonisolated static let reservedAttributes: Set<String> = ["style", "class", "data-scui"]

    /// Element names that support the native `disabled` attribute.
    ///
    /// `<a>` doesn't — its disabled semantics come from omitting `href`
    /// instead, handled separately above — so it's excluded here to avoid
    /// emitting an attribute the HTML spec doesn't define for it.
    nonisolated static let disablableElementNames: Set<String> = ["button", "input"]

    /// Formats a `Double` the way a numeric HTML attribute expects: no
    /// trailing `.0` for whole numbers, since `min`/`max`/`value` on
    /// `<input type=range>` are otherwise indistinguishable from an author
    /// having actually asked for a fractional bound.
    nonisolated static func formatNumber(_ value: Double) -> String {
        value == value.rounded() && value.isFinite
            ? String(Int(value))
            : String(value)
    }

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
