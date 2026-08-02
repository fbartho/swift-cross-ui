import Foundation
@_spi(Backends) import SwiftCrossUI

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
    BackendFeatures.Windowing
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
        /// Resolved from ``pendingTagRequest`` once the whole tree is built;
        /// see ``StaticHTMLRenderer``.
        public var explicitElement: HTMLElement?
        /// Attributes requested via ``View/htmlAttributes(_:)``.
        public var authorAttributes: [String: String] = [:]
        /// The tag request that was in scope when this widget was updated.
        ///
        /// A request is in scope for every descendant of the modified view, so
        /// this alone doesn't say which element should carry it. The renderer
        /// resolves that by giving each request to the topmost widget that saw
        /// it.
        var pendingTagRequest: HTMLTagRequest?
        /// The attributes request that was in scope when this widget was
        /// updated.
        var pendingAttributesRequest: HTMLAttributesRequest?
        /// The href request that was in scope when this widget was updated.
        var pendingHrefRequest: HTMLHrefRequest?
        /// The raw-fragment request that was in scope when this widget was
        /// updated.
        var pendingRawFragmentRequest: HTMLRawFragmentRequest?
        /// Markup this widget should be replaced by, resolved from
        /// ``pendingRawFragmentRequest`` once the whole tree is built.
        ///
        /// Set only on the zero-size leaf a ``RawHTMLFragment`` or
        /// ``SlotComponent`` produces; the emitter writes it out in place of
        /// the element it would otherwise have emitted.
        public var rawFragment: HTMLRawFragmentRequest?
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

        public var naturalSize: SIMD2<Int> {
            .zero
        }

        public func getChildren() -> [Widget] {
            []
        }

        /// Records the authored intent in scope when this widget was updated.
        ///
        /// - Parameter environment: The environment the widget was updated in.
        func captureIntent(from environment: EnvironmentValues) {
            pendingTagRequest = environment.htmlTagRequest
            pendingAttributesRequest = environment.htmlAttributesRequest
            pendingHrefRequest = environment.htmlHrefRequest
            pendingRawFragmentRequest = environment.htmlRawFragmentRequest
            isEnabled = environment.isEnabled
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

    /// A button, which in static output becomes a link.
    public class Button: Widget {
        public var label = ""
        public var font: Font.Resolved?

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
        public var alignment: StackAlignment
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
    public var defaultPaddingAmount = 10
    public var scrollBarWidth = 8
    public var requiresToggleSwitchSpacer = false
    public var requiresImageUpdateOnScaleFactorChange = false
    public var deviceClass = DeviceClass.desktop
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
        alignment: StackAlignment,
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
        textView.textAlignment = environment.multilineTextAlignment
        textView.lineLimit = environment.lineLimitSettings
        textView.isTextSelectionEnabled = environment.isTextSelectionEnabled
        textView.captureIntent(from: environment)
    }

    public func createButton() -> Widget {
        Button()
    }

    public func updateButton(
        _ button: Widget,
        label: String,
        environment: EnvironmentValues,
        action: @escaping () -> Void
    ) {
        let button = button as! Button
        button.label = label
        button.font = environment.resolvedFont
        button.captureIntent(from: environment)
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
    private func pair(
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
