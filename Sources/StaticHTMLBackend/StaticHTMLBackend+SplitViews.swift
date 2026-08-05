@_spi(Backends) import SwiftCrossUI
import SwiftCrossUIComponents

// A split view's native behaviour is a draggable divider between two panes.
// Only half of that survives to this tier: both panes render, side by side, and
// the reader can read either — but nothing drags, because a static page has no
// script to move a divider with. The sidebar's width is therefore a layout
// decision made once, at emission, rather than a live value.
extension StaticHTMLBackend {
    /// A split view holding a sidebar and a detail pane.
    public class SplitViewWidget: Widget {
        public var leadingChild: Widget
        public var trailingChild: Widget
        /// The narrowest the sidebar may be, from
        /// ``BackendFeatures/SplitViews/setSidebarWidthBounds(ofSplitView:minimum:maximum:)``.
        ///
        /// Emitted as a CSS `min-width` so the sidebar can't be squeezed below
        /// the width its own content needs, which is the bound's meaning.
        public var minimumSidebarWidth: Int?
        /// The widest the sidebar may be, as ``minimumSidebarWidth`` is for the
        /// narrowest.
        public var maximumSidebarWidth: Int?

        public init(leadingChild: Widget, trailingChild: Widget) {
            self.leadingChild = leadingChild
            self.trailingChild = trailingChild
        }

        public override func getChildren() -> [Widget] {
            [leadingChild, trailingChild]
        }
    }

    /// The sidebar width this backend reports to the layout system.
    ///
    /// The protocol asks for a live width — on a native backend this is
    /// whatever the reader last dragged the divider to. Static output has no
    /// divider and no reader interaction to have moved one, so the value is a
    /// fixed default rather than a measurement. 260px matches the sidebar width
    /// AppKit and WinUI open a split view at, which keeps the build host's
    /// layout pass measuring the panes against roughly the same split a native
    /// rendering would.
    static let defaultSidebarWidth = 260

    // MARK: - Split views

    public func createSplitView(leadingChild: Widget, trailingChild: Widget) -> Widget {
        SplitViewWidget(leadingChild: leadingChild, trailingChild: trailingChild)
    }

    public func sidebarWidth(ofSplitView splitView: Widget) -> Int {
        // Called during `computeLayout`, before any bounds have been set, so
        // this can't derive from `minimumSidebarWidth`/`maximumSidebarWidth` —
        // they're still nil on the first pass. The constant is what makes the
        // reported width stable across passes, which matters because the core
        // calls this again during `commit` and positions the panes against it.
        Self.defaultSidebarWidth
    }

    public func setSidebarWidthBounds(
        ofSplitView splitView: Widget,
        minimum minimumWidth: Int,
        maximum maximumWidth: Int
    ) {
        let splitView = splitView as! SplitViewWidget
        splitView.minimumSidebarWidth = minimumWidth
        splitView.maximumSidebarWidth = maximumWidth
    }

    public func setResizeHandler(ofSplitView splitView: Widget, to action: @escaping () -> Void) {
        // No-op with no static meaning to recover: the handler fires when the
        // reader drags the divider, and this tier emits no divider to drag.
        // Unlike a control's dropped action, there's nothing to mark for a
        // later tier either — the callback belongs to the pane geometry, which
        // a runtime tier would own wholesale rather than attach to an element.
    }
}
