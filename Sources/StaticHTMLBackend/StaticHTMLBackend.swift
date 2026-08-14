import Foundation
@_spi(Backends) import SwiftCrossUI
import SwiftCrossUIComponents

/// A backend that renders a view tree to a standalone HTML document.
///
/// The document is produced on the build host: the real layout system runs
/// headlessly, negotiating sizes and positions exactly as it would under a
/// windowing backend, and the committed widget tree is then serialized. There
/// is no runtime, no wasm, and no script in the output.
///
/// Rendering goes through ``StaticHTMLRenderer``, which drives this backend
/// twice — once per color scheme — so that colors can be emitted as CSS
/// custom properties that follow the reader's system appearance.
public final class StaticHTMLBackend:
    BaseAppBackend,
    BackendFeatures.CornerRadius,
    BackendFeatures.Colors,
    BackendFeatures.Tables,
    BackendFeatures.Windowing,
    HTMLElementAnchoring
{
    /// A window. Static output has no real windows; this only carries the
    /// size that the root view gets laid out against.
    public class Window {
        static let defaultSize = SIMD2<Int>(800, 600)

        public var size: SIMD2<Int>
        public var id: String
        public var minimumSize: SIMD2<Int> = .zero
        public var maximumSize: SIMD2<Int>?
        public var title = "Window"
        public var resizable = true
        public var content: Widget?
        public var phase = ScenePhase.active

        public init(defaultSize: SIMD2<Int>?, id: String) {
            size = defaultSize ?? Self.defaultSize
            self.id = id
        }
    }

    /// A node in the tree that gets serialized to HTML.
    ///
    /// Widgets accumulate two kinds of information: geometry, which the layout
    /// system writes as it commits, and authored intent (headings, explicit
    /// element names, attributes), which the backend captures from the
    /// environment at the seams that carry one.
    public class Widget {
        /// The view type name that the core stamps onto every widget, e.g.
        /// `"VStack"`. Retained in the output as `data-scui`.
        public var tag: String?
        /// The widget's committed size.
        public var size = SIMD2<Int>.zero
        /// The widget's corner radius, if one was applied.
        public var cornerRadius = 0
        /// An element name explicitly requested via ``View/htmlTag(_:)``.
        ///
        /// Resolved from ``pendingElement`` onto the element of the view the
        /// author modified.
        public var explicitElement: HTMLElement?
        /// The element name captured onto this widget by a
        /// ``View/htmlTag(_:)`` modifier.
        ///
        /// The modifier owns a wrapper around the view the author named, not
        /// that view's own widget, so the name descends from here to the
        /// element the author was describing and never leaves that subtree.
        var pendingElement: HTMLElement?
        /// Attribute operations this widget's element carries.
        ///
        /// Populated as blocks are resolved — either here, when the block
        /// names an `id`, or by the first element surviving elision beneath
        /// the application site. See ``HTMLAttributeBlock/materializes``.
        public var authorAttributes: [String: HTMLAttributeOp] = [:]
        /// The attribute block captured onto this widget that names no `id`.
        ///
        /// It describes no element of its own, so it rides past the author's
        /// modified view to the first element that survives elision.
        var pendingAttributes: HTMLAttributeBlock?
        /// The `id`-bearing attribute block captured onto this widget.
        ///
        /// Kept apart from ``pendingAttributes`` because the two stop in
        /// different places: an author-designated identity lands on the
        /// modified view's own element and keeps it alive, rather than riding
        /// on to whatever elision leaves.
        var pendingIdentifiedAttributes: HTMLAttributeBlock?
        /// The navigation destination in scope when this widget was updated.
        ///
        /// Href-capable widgets consume this into ``href``; everything else
        /// merely carries it so the emitter can tell an unconsumed
        /// destination from an absent one.
        var pendingHref: String?
        /// The raw-fragment request that was in scope when this widget was
        /// updated.
        var pendingRawFragmentRequest: HTMLRawFragmentRequest?
        /// Markup this widget should be replaced by, resolved from
        /// ``pendingRawFragmentRequest`` once the whole tree is built.
        ///
        /// Set only on the zero-size leaf a ``HTMLRawFragment`` or
        /// ``HTMLSlot`` produces; the emitter writes it out in place of
        /// the element it would otherwise have emitted.
        public var rawFragment: HTMLRawFragmentRequest?

        /// Whether this widget's subtree bottoms out at a raw-fragment leaf,
        /// following single-child wrapping only.
        ///
        /// `HTMLRawFragment`/`HTMLSlot` produce several levels of
        /// single-child `Container` (``StrictFrameView``'s `.frame(width: 0,
        /// height: 0)`, `.transformEnvironment`'s wrapper, the view's own
        /// boundary) around the leaf that actually carries ``rawFragment``.
        /// Every one of those ancestors has the same honestly-computed
        /// `0x0` committed size — the leaf really was told to be that size —
        /// but that size is meaningless once the wrapper reaches this
        /// property: the real content the leaf's markup replaces itself
        /// with has no size on the build host at all (see
        /// ``HTMLRawFragment``'s documented cost), so an ancestor trusting
        /// its own committed `0x0` as a real box is what lets the spliced
        /// content overlap a flex sibling instead of the wrapper
        /// participating in the parent's layout directly. See
        /// ``HTMLEmitter/emitChildren(of:style:indent:indentLevel:stretchesUndeclaredAxis:)``.
        var wrapsRawFragment: Bool {
            if rawFragment != nil {
                return true
            }
            let children = getChildren()
            guard children.count == 1 else {
                return false
            }
            return children[0].wrapsRawFragment
        }
        /// Whether this widget would emit an element that exists only to hold
        /// its children — nothing an author asked for is riding on it.
        ///
        /// Used to decide whether a wrapper may be dropped. Committed geometry
        /// is not consulted — every widget has some — but a frame the author
        /// *declared* counts, which ``Container/isStructuralWrapper`` answers
        /// for the one widget type that can carry one.
        ///
        /// Only valid once attribute blocks have been resolved onto their
        /// consumers, since ``authorAttributes`` is one of the things that
        /// pins an element here.
        var carriesNoAuthoredIntent: Bool {
            if let container = self as? Container, !container.isStructuralWrapper {
                return false
            }
            return explicitElement == nil && authorAttributes.isEmpty && href == nil
                && rawFragment == nil && referencedIdentifier == nil && labelledBy == nil
                && cornerRadius == 0 && !awaitsTapEnlivening && isEnabled
                && !isSpacer && !isDivider && declaredAspectRatio == nil
        }

        /// Whether ``View/disabled(_:)`` was in scope when this widget was
        /// updated.
        ///
        /// A static render has no interaction to actually disable, but the
        /// still image has to say so: leaving a disabled control looking
        /// live is actively misleading rather than merely incomplete.
        public var isEnabled = true
        /// The href requested via ``View/href(_:)``, if any.
        ///
        /// Distinct from ``isEnabled``: `isEnabled` is the author explicitly
        /// saying "this control shouldn't respond" (`.disabled(true)`), which
        /// stays a hard override regardless of tier. `href` is the *tier*
        /// signal — it's what tells the emitter a Button/NavigationLink's
        /// element is resolvable in pure HTML (a live `<a>`) rather than
        /// waiting on a runtime to enliven it (a `<button disabled>`). See
        /// the button case in ``HTMLEmitter/emit(_:at:placement:indentLevel:inheritedFrame:stretchesUndeclaredAxis:flexShrinkWeight:)``
        /// for the emission matrix this drives.
        public var href: String?
        /// Whether a tap gesture was attached here that only a runtime tier
        /// can deliver, from
        /// ``StaticHTMLBackend/updateTapGestureTarget(_:gesture:environment:action:)``.
        ///
        /// Like ``href``, this is a tier signal rather than an author
        /// override: it says the element has interaction waiting on a tier
        /// that isn't present, which is what the emitter turns into
        /// `data-scui-enliven`. Unlike a control, the marked element is
        /// ordinary content — it gets no `disabled`, because there is no
        /// control here to disable and marking arbitrary content disabled
        /// would claim a semantics it doesn't have.
        public var awaitsTapEnlivening = false
        /// The `id` this widget has to carry because something else refers to
        /// it, from ``StaticHTMLRenderer``'s label-association pass.
        ///
        /// Only set where a reference exists. A control's label and the
        /// control itself are separate views in the tree — `Toggle` builds an
        /// `HStack { Text(label); Checkbox() }` in user space — so nothing
        /// below the emitter knows they belong together; the pass that does
        /// know writes this and ``labelledBy``.
        public var referencedIdentifier: String?
        /// The `id` of the element naming this control, emitted as
        /// `aria-labelledby`.
        public var labelledBy: String?
        /// The aspect ratio declared via
        /// ``SwiftCrossUI/View/aspectRatio(_:contentMode:)``, from
        /// ``BackendFeatures/Widgets/describeAspectRatio(of:ratio:contentMode:)``.
        ///
        /// `nil` covers two different things the emitter can't tell apart
        /// and doesn't need to: the modifier was never applied, or it was
        /// applied with no explicit ratio (adopting the child's own ideal
        /// ratio) — a value only the layout system could compute, not
        /// something safe to re-derive at another width. Either way, this
        /// widget's undeclared cross axis falls back to committed geometry
        /// like any other unframed leaf.
        public var declaredAspectRatio: Double?
        /// Whether this widget is standing in for a ``SwiftCrossUI/Spacer``,
        /// from ``BackendFeatures/Widgets/describeSpacer(of:)``.
        ///
        /// Replaces matching on the debug ``tag`` string: that tag is
        /// stamped generically on every widget for debugging and isn't a
        /// contract views can rely on, whereas this is set deliberately by
        /// `Spacer` itself.
        public var isSpacer = false
        /// Whether this widget is standing in for a ``SwiftCrossUI/Divider``,
        /// from ``BackendFeatures/Widgets/describeDivider(of:)``. See
        /// ``isSpacer`` for why this replaces a ``tag`` string match.
        public var isDivider = false
        /// Whether this widget sits inside a ``ViewLabelButton``'s label
        /// subtree, from ``StaticHTMLRenderer``'s label-boundary pass.
        ///
        /// A button label renders styled text, never a document heading — its
        /// declared font is what makes the label look right, not a claim
        /// about outline structure. Without this flag, a `Text` inside a
        /// label is indistinguishable from one sitting in ordinary flow
        /// content and derives a heading purely from its font, leaking the
        /// button into the document outline. See ``HeadingMap`` and the
        /// `Text` case in
        /// ``HTMLEmitter/emit(_:at:placement:indentLevel:inheritedFrame:stretchesUndeclaredAxis:flexShrinkWeight:)``.
        var isInsideControlLabel = false

        public var naturalSize: SIMD2<Int> {
            .zero
        }

        public func getChildren() -> [Widget] {
            []
        }

        /// Records the authored intent in scope when this widget was updated.
        ///
        /// Only the values that propagate down a subtree arrive this way. An
        /// element name and an attribute block are anchored directly onto the
        /// modifier's own widget by
        /// ``StaticHTMLBackend/anchor(element:to:)`` and
        /// ``StaticHTMLBackend/anchor(attributes:to:)``.
        ///
        /// - Parameter environment: The environment the widget was updated in.
        func captureIntent(from environment: EnvironmentValues) {
            pendingHref = environment.htmlHref
            pendingRawFragmentRequest = environment.htmlRawFragmentRequest
            isEnabled = environment.isEnabled
        }

        /// Takes the navigation destination in scope as this widget's own.
        ///
        /// Called by the href-capable widgets — the ones whose emission matrix
        /// has a live-anchor row — after they capture their intent. A widget
        /// that never calls this leaves the destination to the consumers below
        /// it, which is what lets one `.href(_:)` on a container light up every
        /// link inside it.
        func consumeHref() {
            href = pendingHref
            pendingHref = nil
        }
    }

    /// A text widget.
    public class TextView: Widget {
        public var content = ""
        public var font: Font.Resolved?
        /// The un-resolved font, which is what carries the author's declared
        /// text style and therefore the document's heading structure.
        public var declaredFont: Font?
        public var color: SchemePair?
        /// Whether ``color`` came from ``SwiftCrossUI/View/foregroundColor(_:)``
        /// rather than from the scheme's default.
        ///
        /// ``color`` is always populated — the emitter writes a color on every
        /// run of text — so it can't answer whether the author chose one.
        public var hasDeclaredColor = false
        /// The alignment of lines relative to each other, from
        /// ``SwiftCrossUI/View/multilineTextAlignment(_:)``.
        public var textAlignment: HorizontalAlignment = .leading
        /// The line-height limit from ``SwiftCrossUI/View/lineLimit(_:reservesSpace:)``,
        /// if the author set one.
        public var lineLimit: LineLimit?
        /// Whether the text should be selectable, from
        /// ``SwiftCrossUI/View/textSelectionEnabled(_:)``.
        public var isTextSelectionEnabled = false
    }

    /// A button whose label is a plain string, used by ``SwiftCrossUI/Toggle``
    /// and ``SwiftCrossUI/Menu``.
    ///
    /// ``SwiftCrossUI/Button`` takes an arbitrary view as its label and so
    /// emits from ``StaticHTMLBackend/ViewLabelButton`` instead.
    public class SimpleButton: Widget {
        public var label = ""
        public var font: Font.Resolved?
        /// The style resolved from the environment by
        /// ``SwiftCrossUI/View/buttonStyle(_:)``, falling back to
        /// ``StaticHTMLBackend/defaultButtonStyle()``.
        public var style: ButtonStyle = .bordered

        /// Buttons take their intrinsic size from the backend, so leaving this
        /// at zero would render them 0x0. Estimated from the label the same
        /// way ``StaticHTMLBackend/size(of:whenDisplayedIn:proposedWidth:proposedHeight:environment:)``
        /// measures text.
        override public var naturalSize: SIMD2<Int> {
            guard let font else { return .zero }
            let characterHeight = Int(font.pointSize)
            let characterWidth = characterHeight * 2 / 3
            let horizontalPadding = 10
            let verticalPadding = 5
            return SIMD2(
                characterWidth * label.count + horizontalPadding * 2,
                Int(font.lineHeight) + verticalPadding * 2
            )
        }
    }

    /// A button whose label is an arbitrary view, used by
    /// ``SwiftCrossUI/Button``.
    ///
    /// Unlike every other control this backend emits, a button owns a child
    /// subtree rather than a string, so the emitter renders its label by
    /// walking that subtree instead of escaping a stored value.
    public class ViewLabelButton: Widget {
        /// The widget rendered inside the button.
        public var label: Widget

        /// The style resolved from the environment by
        /// ``SwiftCrossUI/View/buttonStyle(_:)``, falling back to
        /// ``StaticHTMLBackend/defaultButtonStyle()``.
        public var buttonStyle: ButtonStyle = .bordered

        /// Creates a button wrapping the given label widget.
        ///
        /// - Parameter label: The widget to render inside the button.
        public init(label: Widget) {
            self.label = label
        }

        public override func getChildren() -> [Widget] {
            [label]
        }
    }

    /// A solid rectangle of color.
    public class Rectangle: Widget {
        public var color: SchemePair?
    }

    /// How a container's children were arranged by the layout system.
    ///
    /// Recorded so that the emitter can re-express the arrangement as CSS flow
    /// instead of pinning each child to the coordinates it was given. The
    /// committed geometry alone can't say this: a stack holding one child and
    /// an overlay holding one child are positioned identically.
    public struct StackLayout: Hashable, Sendable {
        /// The axis the children were stacked along.
        public var orientation: Orientation
        /// How the children were aligned across that axis.
        public var alignment: StackAlignmentDescription
        /// The gap left between adjacent children.
        public var spacing: Int
    }

    /// A generic container holding positioned children.
    public class Container: Widget {
        public var children: [(widget: Widget, position: SIMD2<Int>)] = []
        /// How the layout system arranged the children, if it arranged them as
        /// a stack. `nil` means the positions are the only description there
        /// is, and the emitter has to place the children absolutely.
        public var stackLayout: StackLayout?
        /// Each stack child's ``SwiftCrossUI/View/layoutPriority(_:)``,
        /// indexed the same way as ``children``. `nil` for a container the
        /// layout system never described as a stack at all — as opposed to
        /// one that was, where every entry defaults to 0 (SwiftUI's
        /// undeclared priority), which is a real, meaningful value the
        /// emitter still needs to see.
        public var childLayoutPriorities: [Double]?
        /// Whether this container is standing in for a
        /// ``SwiftCrossUI/View/background(_:)`` pair, from
        /// ``BackendFeatures/Widgets/describeBackground(of:)``.
        ///
        /// `children` is always exactly `[backdrop, foreground]` in that
        /// order when this is set (``BackgroundModifier/body`` is a
        /// `TupleView2(background, foreground)`, and ``BackgroundModifier/commit``
        /// positions index 0/1 accordingly) — the emitter special-cases this
        /// shape instead of routing it through the generic overlap-pin path
        /// every other two-child, always-overlapping container takes, since
        /// a ``ZStack``'s overlap is declared author intent to preserve
        /// while a background's backdrop should track the foreground's box
        /// at whatever width the browser reflows it to.
        public var isBackgroundLayering = false
        /// The width the author fixed with ``SwiftCrossUI/View/frame(width:height:alignment:)``.
        ///
        /// Kept apart from ``Widget/size`` because only a dimension the author
        /// asked for should survive into output that otherwise reflows.
        public var declaredWidth: Double?
        /// The height the author fixed, as ``declaredWidth`` is for width.
        public var declaredHeight: Double?
        /// The width constraints the author declared with
        /// ``SwiftCrossUI/View/frame(minWidth:idealWidth:maxWidth:minHeight:idealHeight:maxHeight:alignment:)``.
        ///
        /// Kept apart from ``declaredWidth`` because a range degrades to CSS
        /// min/max rather than to a fixed dimension; `idealWidth` has no CSS
        /// equivalent once the container is already laid out, so it isn't
        /// carried into emission.
        public var declaredMinWidth: Double?
        /// The maximum width the author declared, as ``declaredMinWidth`` is
        /// for the minimum.
        public var declaredMaxWidth: Double?
        /// The minimum height the author declared, as ``declaredMinWidth`` is
        /// for width.
        public var declaredMinHeight: Double?
        /// The maximum height the author declared, as ``declaredMaxWidth`` is
        /// for width.
        public var declaredMaxHeight: Double?

        /// Whether this container declares the `.frame(maxWidth: .infinity)`
        /// stretch idiom itself.
        var declaresInfiniteWidthStretch: Bool {
            declaredMaxWidth == .infinity && declaredWidth == nil
        }

        /// Whether this container is a structural wrapper — one the view tree
        /// produced to hold children, not one the author declared anything
        /// about.
        ///
        /// `ForEach`, `Group`, the `TupleView`s a `ViewBuilder` block expands
        /// to, and the `EitherView` an `if`/`else` produces are the cases that
        /// matter: they arrive here as ordinary containers, indistinguishable
        /// from a `VStack` the author wrote, except that no frame was ever
        /// declared on them. That distinction is what makes it safe to let a
        /// child's stretch intent pass through them — see
        /// ``relaysChildStretch``.
        ///
        /// A `.background()` pair is deliberately excluded even though it
        /// declares no frame of its own: it's a real box whose width tracks
        /// its foreground, and it reaches emission through its own branch
        /// rather than the paths this property feeds.
        var isStructuralWrapper: Bool {
            declaredWidth == nil && declaredHeight == nil
                && declaredMinWidth == nil && declaredMaxWidth == nil
                && declaredMinHeight == nil && declaredMaxHeight == nil
                && !isBackgroundLayering
        }

        /// Whether this container's subtree carries a stretch that an
        /// ancestor has to re-declare for it to take effect.
        ///
        /// Descends through wrappers that pass their own width straight to
        /// the child — structural wrappers, and a `.background()` pair, whose
        /// foreground keeps flow sizing (so a stretch inside one is still a
        /// live request against whatever box the pair ends up being). It
        /// stops at any container that declares a width of its own: that
        /// declaration is the author's answer for everything below it.
        var containsRelayableStretch: Bool {
            if declaresInfiniteWidthStretch {
                return true
            }
            guard isStructuralWrapper || isBackgroundLayering else {
                return false
            }
            return children.contains { child in
                (child.widget as? Container)?.containsRelayableStretch ?? false
            }
        }

        /// Whether a descendant's `.frame(maxWidth: .infinity)` stretch has to
        /// be re-declared on this container to reach the enclosing stack.
        ///
        /// `align-self` only ever addresses an element's own parent, so a
        /// stretch declared several levels down stops at the first ancestor
        /// that shrink-wraps. A structural wrapper is exactly such an
        /// ancestor: it's a flex item of the stack above it with
        /// `align-self:auto`, so it takes that stack's `align-items` —
        /// `flex-start` in a leading-aligned column — and content-sizes,
        /// leaving the stretching descendant filling a box that is itself
        /// only as wide as its content.
        ///
        /// Only wrappers the author declared nothing about relay
        /// (``isStructuralWrapper``); a container carrying its own frame is a
        /// real box whose width is the author's answer to this question.
        var relaysChildStretch: Bool {
            guard isStructuralWrapper else {
                return false
            }
            return children.contains { child in
                (child.widget as? Container)?.containsRelayableStretch ?? false
            }
        }

        public override func getChildren() -> [Widget] {
            children.map(\.widget)
        }
    }

    /// A scrollable container.
    public class ScrollContainer: Widget {
        public var child: Widget

        public init(child: Widget) {
            self.child = child
        }

        public override func getChildren() -> [Widget] {
            [child]
        }
    }

    public var defaultTableRowContentHeight = 10
    public var defaultTableCellVerticalPadding = 10
    /// The vertical padding emitted on table cells.
    ///
    /// Matches ``defaultTableCellVerticalPadding``, which is what the layout
    /// system measured rows against, so the browser's own row heights land
    /// near the build host's estimate.
    static let tableCellVerticalPadding = 10
    /// The horizontal padding emitted on table cells.
    ///
    /// No protocol method reports a horizontal equivalent — the core only asks
    /// about the vertical axis — so this is the backend's own choice, wide
    /// enough to separate adjacent columns without a ruling line between them.
    static let tableCellHorizontalPadding = 12
    public var defaultPaddingAmount = 10
    public var scrollBarWidth = 8
    public var requiresToggleSwitchSpacer = false
    public var requiresImageUpdateOnScaleFactorChange = false
    // The web anchors to Apple's iOS metrics, not the macOS ones: the macOS
    // 13pt body is a dense-UI size that reads as too small in a browser, and
    // Apple's own web properties ship the iOS 17pt body instead. Reporting
    // .phone is what makes the layout system measure against the same table
    // ``TypeScale`` emits, so build-host estimates and the browser agree on
    // which ramp is in play.
    public var deviceClass = DeviceClass.phone
    public var supportsMultipleWindows = false
    public var supportedPickerStyles: [BackendPickerStyle] = []
    public let canOverrideWindowColorScheme = true
    public let restoresWindowFrames = false

    public var appPhase = AppPhase.active

    /// The color scheme that this pass renders in.
    ///
    /// ``StaticHTMLRenderer`` runs one pass per scheme and diffs the results.
    public let colorScheme: ColorScheme

    /// Creates a backend that renders in the light color scheme.
    public convenience init() {
        self.init(colorScheme: .light)
    }

    /// Creates a backend that renders in a given color scheme.
    ///
    /// - Parameter colorScheme: The scheme to resolve colors against.
    public init(colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
    }

    public func runMainLoop(_ callback: @escaping @MainActor () -> Void) {
        callback()
    }

    public func createWindow(withDefaultSize defaultSize: SIMD2<Int>?, id: String) -> Window {
        Window(defaultSize: defaultSize, id: id)
    }

    public func updateWindow(_ window: Window, environment: EnvironmentValues) {}

    public func setTitle(ofWindow window: Window, to title: String) {
        window.title = title
    }

    public func setBehaviors(
        ofWindow window: Window,
        closable: Bool,
        minimizable: Bool,
        resizable: Bool
    ) {
        window.resizable = resizable
    }

    public func setChild(ofWindow window: Window, to child: Widget) {
        window.content = child
    }

    public func size(ofWindow window: Window) -> SIMD2<Int> {
        window.size
    }

    public func isWindowProgrammaticallyResizable(_ window: Window) -> Bool {
        false
    }

    public func setSize(ofWindow window: Window, to newSize: SIMD2<Int>) {
        window.size = newSize
    }

    public func setSizeLimits(
        ofWindow window: Window,
        minimum minimumSize: SIMD2<Int>,
        maximum maximumSize: SIMD2<Int>?
    ) {
        window.minimumSize = minimumSize
        window.maximumSize = maximumSize
    }

    public func setResizeHandler(
        ofWindow window: Window,
        to action: @escaping (SIMD2<Int>) -> Void
    ) {}

    public func show(window: Window) {}

    public func activate(window: Window) {}

    public func close(window: Window) {}

    public func setCloseHandler(ofWindow window: Window, to action: @escaping () -> Void) {}

    public func runInMainThread(action: @escaping @MainActor () -> Void) {
        // `StaticHTMLRenderer.render` is itself `@MainActor`, so the common
        // case really is already on the MainActor executor and
        // `assumeIsolated` would be correct. But `observeAsUIUpdater`
        // (used by every `@State`/`@Environment` property, not just
        // `.task`/`.onChange`) registers its observer during
        // `ViewGraphNode.init` by hopping to a background serial queue
        // first, so this can also be reached off the true MainActor -
        // `assumeIsolated` would then trap with "Incorrect actor executor
        // assumption" instead of running the action.
        //
        // A one-shot render has no run loop spinning after `render`
        // returns, so deferring with `DispatchQueue.main.async` (as
        // `DummyBackend` does) would silently never run the action here.
        // Running it synchronously, on whichever thread actually reaches
        // this call, is what makes a one-shot render's state observation
        // behave the same as every other path through the render: it just
        // happens now, because for this backend there is no "later".
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                action()
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    action()
                }
            }
        }
    }

    public func computeRootEnvironment(
        defaultEnvironment: EnvironmentValues
    ) -> EnvironmentValues {
        defaultEnvironment
            .with(\.appPhase, appPhase)
            .with(\.colorScheme, colorScheme)
    }

    public func setRootEnvironmentChangeHandler(
        to action: @escaping @Sendable @MainActor () -> Void
    ) {}

    public func computeWindowEnvironment(
        window: Window,
        rootEnvironment: EnvironmentValues
    ) -> EnvironmentValues {
        rootEnvironment.with(\.scenePhase, window.phase)
    }

    public func setWindowEnvironmentChangeHandler(
        of window: Window,
        to action: @escaping @Sendable @MainActor () -> Void
    ) {}

    public func show(widget: Widget) {}

    public func tag(widget: Widget, as tag: String) {
        widget.tag = tag
    }

    public func createContainer() -> Widget {
        Container()
    }

    /// Records the element an author named for this widget.
    ///
    /// The widget is the modifier's own wrapper, which is the application
    /// site: one application, one wrapper, so nothing has to recover which
    /// application a name came from. Which *element* it names is settled
    /// during emission, by descending to the author's modified view.
    ///
    /// - Parameters:
    ///   - element: The element to emit it as.
    ///   - widget: The modifier's wrapper widget.
    public func anchor(element: HTMLElement, to widget: Widget) {
        // A name already here was applied closer to the content, which is the
        // more specific answer.
        widget.pendingElement = widget.pendingElement ?? element
    }

    /// Records a block of attribute operations an author attached to this
    /// widget.
    ///
    /// Whether the block materializes an element decides where it lands, not
    /// where it starts: both kinds start here, on the modifier's wrapper, and
    /// descend to the author's modified view during emission. A block naming
    /// an `id` stops at that view and keeps its element alive; a block naming
    /// none rides on to the first element that survives elision.
    ///
    /// - Parameters:
    ///   - attributes: The attribute operations to apply.
    ///   - widget: The modifier's wrapper widget.
    public func anchor(attributes: HTMLAttributeBlock, to widget: Widget) {
        guard attributes.materializes else {
            // A block applied closer to the content wins the keys it sets.
            widget.pendingAttributes = widget.pendingAttributes.map { pending in
                attributes.layering(pending)
            } ?? attributes
            return
        }
        widget.pendingIdentifiedAttributes = widget.pendingIdentifiedAttributes.map { pending in
            attributes.layering(pending)
        } ?? attributes
    }

    public func removeAllChildren(of container: Widget) {
        (container as! Container).children = []
    }

    public func insert(_ child: Widget, into container: Widget, at index: Int) {
        (container as! Container).children.insert((child, .zero), at: index)
    }

    public func swap(childAt firstIndex: Int, withChildAt secondIndex: Int, in container: Widget) {
        (container as! Container).children.swapAt(firstIndex, secondIndex)
    }

    public func setPosition(ofChildAt index: Int, in container: Widget, to position: SIMD2<Int>) {
        (container as! Container).children[index].position = position
    }

    public func remove(childAt index: Int, from container: Widget) {
        (container as! Container).children.remove(at: index)
    }

    public func createColorableRectangle() -> Widget {
        Rectangle()
    }

    public func setColor(
        ofColorableRectangle widget: Widget,
        to color: Color.Resolved,
        environment: EnvironmentValues
    ) {
        let rectangle = widget as! Rectangle
        rectangle.color = pair(forResolved: color, existing: rectangle.color)
        rectangle.captureIntent(from: environment)
    }

    public func createCornerRadiusContainer(wrapping child: Widget) -> Widget {
        child
    }

    public func setCornerRadius(of widget: Widget, to radius: Int) {
        widget.cornerRadius = radius
    }

    public func naturalSize(of widget: Widget) -> SIMD2<Int> {
        widget.naturalSize
    }

    public func setSize(of widget: Widget, to size: SIMD2<Int>) {
        widget.size = size
    }

    public func describeStackLayout(
        of widget: Widget,
        orientation: Orientation,
        alignment: StackAlignmentDescription,
        spacing: Int
    ) {
        (widget as? Container)?.stackLayout = StackLayout(
            orientation: orientation,
            alignment: alignment,
            spacing: spacing
        )
    }

    public func describeChildLayoutPriorities(of widget: Widget, priorities: [Double]) {
        (widget as? Container)?.childLayoutPriorities = priorities
    }

    public func describeFrame(of widget: Widget, width: Double?, height: Double?) {
        guard let container = widget as? Container else {
            return
        }
        container.declaredWidth = width
        container.declaredHeight = height
    }

    public func describeFlexibleFrame(
        of widget: Widget,
        minWidth: Double?,
        idealWidth: Double?,
        maxWidth: Double?,
        minHeight: Double?,
        idealHeight: Double?,
        maxHeight: Double?
    ) {
        guard let container = widget as? Container else {
            return
        }
        container.declaredMinWidth = minWidth
        container.declaredMaxWidth = maxWidth
        container.declaredMinHeight = minHeight
        container.declaredMaxHeight = maxHeight
    }

    public func describeAspectRatio(of widget: Widget, ratio: Double?, contentMode: ContentMode) {
        widget.declaredAspectRatio = ratio
    }

    public func describeSpacer(of widget: Widget) {
        widget.isSpacer = true
    }

    public func describeDivider(of widget: Widget) {
        widget.isDivider = true
    }

    public func describeBackground(of widget: Widget) {
        (widget as? Container)?.isBackgroundLayering = true
    }

    public func createScrollContainer(for child: Widget) -> Widget {
        ScrollContainer(child: child)
    }

    public func updateScrollContainer(
        _ scrollView: Widget,
        environment: EnvironmentValues,
        bounceHorizontally: Bool,
        bounceVertically: Bool,
        hasHorizontalScrollBar: Bool,
        hasVerticalScrollBar: Bool
    ) {
        scrollView.captureIntent(from: environment)
    }

    public func size(
        of text: String,
        whenDisplayedIn widget: Widget,
        proposedWidth: Int?,
        proposedHeight: Int?,
        environment: EnvironmentValues
    ) -> SIMD2<Int> {
        // Text measurement has to be an estimate: there's no font engine on
        // the build host that would agree with the browser that eventually
        // renders this. The ratio matches DummyBackend's so that layouts stay
        // comparable between the two.
        let resolvedFont = environment.resolvedFont
        let lineHeight = Int(resolvedFont.lineHeight)
        let characterHeight = Int(resolvedFont.pointSize)
        let characterWidth = characterHeight * 2 / 3

        guard let proposedWidth else {
            return SIMD2(characterWidth * text.count, lineHeight)
        }

        let charactersPerLine = max(1, proposedWidth / characterWidth)
        var lineCount = (text.count + charactersPerLine - 1) / charactersPerLine
        if let proposedHeight {
            lineCount = min(max(1, proposedHeight / lineHeight), lineCount)
        }

        return SIMD2(
            characterWidth * min(charactersPerLine, text.count),
            lineHeight * lineCount
        )
    }

    public func createTextView() -> Widget {
        TextView()
    }

    public func updateTextView(
        _ textView: Widget,
        content: String,
        environment: EnvironmentValues
    ) {
        let textView = textView as! TextView
        textView.content = content
        textView.font = environment.resolvedFont
        // The un-resolved font is the one that still knows which text style
        // the author asked for, which is what heading derivation keys off.
        textView.declaredFont = environment.font
        textView.color = pair(
            forResolved: environment.suggestedForegroundColor.resolve(in: environment),
            existing: textView.color
        )
        textView.hasDeclaredColor = environment.foregroundColor != nil
        textView.textAlignment = environment.multilineTextAlignment
        textView.lineLimit = environment.lineLimitSettings
        textView.isTextSelectionEnabled = environment.isTextSelectionEnabled
        textView.captureIntent(from: environment)
    }

    public func createSimpleButton() -> Widget {
        SimpleButton()
    }

    public func updateSimpleButton(
        _ button: Widget,
        label: String,
        environment: EnvironmentValues,
        action: @escaping () -> Void
    ) {
        let button = button as! SimpleButton
        button.label = label
        button.font = environment.resolvedFont
        button.style = environment.resolvedButtonStyle
        button.captureIntent(from: environment)
        button.consumeHref()
    }

    public func createButton(wrapping widget: Widget) -> Widget {
        ViewLabelButton(label: widget)
    }

    public func updateButton(
        _ button: Widget,
        environment: EnvironmentValues,
        action: @escaping () -> Void
    ) {
        let button = button as! ViewLabelButton
        button.buttonStyle = environment.resolvedButtonStyle
        button.captureIntent(from: environment)
        button.consumeHref()
    }

    /// Removes the navigation destination from a button label's environment.
    ///
    /// A button consumes the `href` in scope for it, so nothing in its label
    /// subtree is within reach of that destination: a `Shape` or nested view
    /// inside the label must not see a value the control above it already
    /// spent. Clearing it keeps the environment truthful, so no later reader
    /// has to tell an inherited destination from a re-applied one.
    ///
    /// An `.href(_:)` applied *inside* the label re-enters the environment
    /// below this point and is unaffected, which is what makes a link nested
    /// in a button's label still resolve.
    ///
    /// - Parameter environment: The button's own environment.
    /// - Returns: The environment its label is built in.
    public func computeButtonLabelEnvironment(
        from environment: EnvironmentValues
    ) -> EnvironmentValues {
        defaultButtonLabelEnvironment(from: environment).with(\.htmlHref, nil)
    }

    public func buttonPadding(in environment: EnvironmentValues) -> SIMD2<Int> {
        environment.resolvedButtonStyle.padding(forFont: environment.resolvedFont)
    }

    public func defaultButtonStyle() -> ButtonStyle {
        // The emitted default is a bordered button (`.scui-btn-bordered`
        // carries a border and a background), so the style the core resolves
        // for an unstyled button has to say the same thing — the layout
        // system sizes labels against it.
        .bordered
    }

    /// Folds a color resolved in this pass's scheme into a scheme pair.
    ///
    /// Each backend instance only knows one scheme, so it fills in its own
    /// side and leaves the other side equal to it. ``StaticHTMLRenderer``
    /// merges the two passes afterwards.
    ///
    /// - Parameters:
    ///   - resolved: The color as resolved in this pass.
    ///   - existing: The widget's current pair, if it already has one.
    /// - Returns: The updated pair.
    func pair(
        forResolved resolved: Color.Resolved,
        existing: SchemePair?
    ) -> SchemePair {
        switch colorScheme {
            case .light:
                SchemePair(light: resolved, dark: existing?.dark ?? resolved)
            case .dark:
                SchemePair(light: existing?.light ?? resolved, dark: resolved)
        }
    }
}
