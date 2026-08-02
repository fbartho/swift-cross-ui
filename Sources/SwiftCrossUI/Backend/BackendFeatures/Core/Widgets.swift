extension BackendFeatures {
    /// Core backend methods for widget handling. These are required for a
    /// functional backend.
    @MainActor
    public protocol Widgets<Widget>: Sendable {
        /// The underlying widget type.
        associatedtype Widget

        /// The default amount of padding used when a user uses the
        /// ``View/padding(_:_:)`` modifier.
        var defaultPaddingAmount: Int { get }

        /// Shows a widget after it has been created or updated.
        ///
        /// May be unnecessary for some backends. Predominantly used by
        /// ``ViewGraphNode`` after propagating updates.
        ///
        /// Only called once the widget has been added to the widget hierarchy.
        ///
        /// - Parameter widget: The widget to show.
        func show(widget: Widget)

        /// Show a widget after it has been updated. This is unnecessary for most
        /// backends which automatically update the visual appearance of widgets
        /// when their properties get changed.
        ///
        /// The default implementation does nothing.
        ///
        /// It's a guarantee that ``ViewGraphNode/show(widget:)`` will get called
        /// before this method for any given widget.
        ///
        /// - Parameter widget: The widget to process.
        func showUpdate(of widget: Widget)

        /// Adds a short tag to a widget to assist during debugging, if the backend
        /// supports such a feature.
        ///
        /// The default implementation does nothing.
        ///
        /// Some backends may only apply tags under particular conditions such as
        /// when being built in debug mode.
        ///
        /// - Parameters:
        ///   - widget: The widget to tag.
        ///   - tag: The tag.
        func tag(widget: Widget, as tag: String)

        /// Gets the natural size of a given widget.
        ///
        /// E.g. the natural size of a button may be the size of the label (without
        /// line wrapping) plus a bit of padding and a border.
        ///
        /// - Parameter widget: The widget to get the natural size of.
        /// - Returns: The natural size of `widget`.
        func naturalSize(of widget: Widget) -> SIMD2<Int>

        /// Sets the size of a widget.
        ///
        /// In general, View and Scene implementations must call ``setSize(of:to:)``
        /// at least once for any given widget before it appears. Backends such as
        /// AndroidBackend don't handle missing widget sizes very well (often because
        /// of custom container implementations such as AndroidBackend's CustomContainer).
        /// The only exception is the root container widget of windows, as many backends
        /// rely on such containers changing size as the user resizes the window. Backends
        /// that need their root container to have a fixed size can do that in their own
        /// window listeners.
        ///
        /// - Parameters:
        ///   - widget: The widget to set the size of.
        ///   - size: The new size.
        func setSize(of widget: Widget, to size: SIMD2<Int>)

        /// Tells the backend that a container was laid out as a stack, and how.
        ///
        /// The default implementation does nothing. Backends position children
        /// explicitly and so don't need this; it exists for backends that
        /// re-express a layout in a system with its own flow rules, such as
        /// StaticHTMLBackend emitting CSS flex containers. Those backends can't
        /// recover the distinction from the committed geometry alone — a
        /// single-child stack and an overlay look identical once positioned.
        ///
        /// Called during commit, before the container's children are
        /// positioned.
        ///
        /// - Parameters:
        ///   - widget: The container that was laid out as a stack.
        ///   - orientation: The axis the children were stacked along.
        ///   - alignment: How the children were aligned across that axis.
        ///   - spacing: The gap left between adjacent children.
        func describeStackLayout(
            of widget: Widget,
            orientation: Orientation,
            alignment: StackAlignment,
            spacing: Int
        )

        /// Tells the backend the layout priority the stack layout system used
        /// for each of a stack's children, in the same visual order as every
        /// other per-child index (``setPosition(ofChildAt:in:to:)``,
        /// ``swap(childAt:withChildAt:in:)``).
        ///
        /// The default implementation does nothing, as with
        /// ``describeStackLayout(of:orientation:alignment:spacing:)``: a
        /// backend that positions children itself already has layout
        /// priority's *effect* baked into each child's committed size and
        /// needs nothing further. A backend re-expressing the stack in a
        /// system with its own space-distribution rules (a CSS flex
        /// container, say) does need it — nothing in the committed
        /// geometry alone says which children should give up space first
        /// on a reflow the stack layout system never re-ran.
        ///
        /// Called during commit, alongside
        /// ``describeStackLayout(of:orientation:alignment:spacing:)``.
        ///
        /// - Parameters:
        ///   - widget: The container that was laid out as a stack.
        ///   - priorities: Each child's layout priority, indexed the same
        ///     way as the container's children.
        func describeChildLayoutPriorities(of widget: Widget, priorities: [Double])

        /// Tells the backend that a container's size was fixed by the author.
        ///
        /// The default implementation does nothing. As with
        /// ``describeStackLayout(of:orientation:alignment:spacing:)``, this is
        /// for backends that re-express a layout rather than placing widgets
        /// themselves: a committed size doesn't distinguish a dimension the
        /// author pinned from one that merely came out that way, and only the
        /// pinned one should survive into a layout that otherwise reflows.
        ///
        /// - Parameters:
        ///   - widget: The container whose size the author constrained.
        ///   - width: The width the author fixed, if they fixed one.
        ///   - height: The height the author fixed, if they fixed one.
        func describeFrame(of widget: Widget, width: Double?, height: Double?)

        /// Tells the backend that a container's size was constrained (rather
        /// than fixed) by the author, as with
        /// ``SwiftCrossUI/View/frame(minWidth:idealWidth:maxWidth:minHeight:idealHeight:maxHeight:alignment:)``.
        ///
        /// The default implementation does nothing. Kept separate from
        /// ``describeFrame(of:width:height:)`` rather than folding into it:
        /// an exact frame reports a size, a flexible one reports a range, and
        /// a backend re-expressing the layout needs to tell the two apart —
        /// a range degrades to CSS min/max, not to a fixed dimension.
        ///
        /// - Parameters:
        ///   - widget: The container whose size the author constrained.
        ///   - minWidth: The minimum width the author declared, if any.
        ///   - idealWidth: The ideal width the author declared, if any.
        ///   - maxWidth: The maximum width the author declared, if any.
        ///   - minHeight: The minimum height the author declared, if any.
        ///   - idealHeight: The ideal height the author declared, if any.
        ///   - maxHeight: The maximum height the author declared, if any.
        func describeFlexibleFrame(
            of widget: Widget,
            minWidth: Double?,
            idealWidth: Double?,
            maxWidth: Double?,
            minHeight: Double?,
            idealHeight: Double?,
            maxHeight: Double?
        )

        /// Tells the backend that a container's proposed size was reshaped to
        /// maintain an author-declared aspect ratio, as with
        /// ``SwiftCrossUI/View/aspectRatio(_:contentMode:)``.
        ///
        /// The default implementation does nothing. As with
        /// ``describeFrame(of:width:height:)``, this is for backends that
        /// re-express a layout rather than placing widgets themselves: the
        /// committed size already reflects the ratio at the one width the
        /// layout system happened to propose, but only the author's
        /// declared ratio — not that one committed outcome — is a value a
        /// backend can safely re-derive at another width.
        ///
        /// - Parameters:
        ///   - widget: The container whose proposed size was reshaped.
        ///   - ratio: The aspect ratio the author declared. `nil` when the
        ///     view instead adopted its child's own ideal ratio (the
        ///     ``SwiftCrossUI/View/aspectRatio(contentMode:)`` overload with
        ///     no explicit value) — a backend that can't measure a child's
        ///     ideal ratio without running layout again has nothing safe to
        ///     re-derive in that case.
        ///   - contentMode: Whether the ratio should be filled or fitted
        ///     within the proposed size.
        func describeAspectRatio(of widget: Widget, ratio: Double?, contentMode: ContentMode)

        /// Tells the backend that a container is standing in for a
        /// ``SwiftCrossUI/Spacer``.
        ///
        /// The default implementation does nothing. As with
        /// ``describeStackLayout(of:orientation:alignment:spacing:)``, this
        /// is for backends that re-express a layout rather than placing
        /// widgets themselves: a spacer's `layoutPriority(-infinity)`
        /// preference (what tells the layout system to shrink it before any
        /// sibling) is consumed entirely inside the layout system and
        /// leaves no trace in committed geometry, so a backend needing to
        /// reproduce "grows to fill, yields first" in its own space-
        /// distribution model has no other way to recognise the widget.
        ///
        /// - Parameter widget: The container standing in for the spacer.
        func describeSpacer(of widget: Widget)

        /// Tells the backend that a container is standing in for a
        /// ``SwiftCrossUI/Divider``.
        ///
        /// The default implementation does nothing, for the same reason as
        /// ``describeSpacer(of:)``: a divider's "always expands along the
        /// containing stack's minor axis, whatever the stack's own
        /// alignment says" contract is enforced by the layout system and
        /// leaves no trace in committed geometry once laid out at a single
        /// width.
        ///
        /// - Parameter widget: The container standing in for the divider.
        func describeDivider(of widget: Widget)
    }
}

// MARK: Default Implementations

extension BackendFeatures.Widgets {
    public func showUpdate(of widget: Widget) {
        // This only exists for backends such as CursesBackend that need to
        // explicitly be notified that a widget should display queued changes.
        // Most can get away with this empty default implementation.
    }

    public func tag(widget: Widget, as tag: String) {
        // This is only really to assist contributors when debugging backends,
        // so it's safe enough to have a no-op default implementation.
    }

    public func describeStackLayout(
        of widget: Widget,
        orientation: Orientation,
        alignment: StackAlignment,
        spacing: Int
    ) {
        // Backends that position children themselves learn nothing from this.
    }

    public func describeChildLayoutPriorities(of widget: Widget, priorities: [Double]) {
        // As above: a backend that positions children itself already has
        // priority's effect baked into each child's committed size.
    }

    public func describeFrame(of widget: Widget, width: Double?, height: Double?) {
        // As above: the committed size already says everything most backends
        // need to know.
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
        // As above: the committed size already says everything most backends
        // need to know.
    }

    public func describeAspectRatio(of widget: Widget, ratio: Double?, contentMode: ContentMode) {
        // As above: the committed size already says everything most backends
        // need to know.
    }

    public func describeSpacer(of widget: Widget) {
        // As above: a backend that positions children itself already has
        // the spacer's effect baked into its committed size.
    }

    public func describeDivider(of widget: Widget) {
        // As above: a backend that positions children itself already has
        // the divider's effect baked into its committed size.
    }
}
