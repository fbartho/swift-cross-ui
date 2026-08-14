extension View {
    /// Overlays another view on top of this view.
    ///
    /// - Parameter alignment: The alignment that the modifier uses to position
    ///   the overlay relative to the underlying content.
    /// - Parameter content: The view to overlay this view with.
    public func overlay(
        alignment: Alignment = .center,
        @ViewBuilder content: () -> some View
    ) -> some View {
        OverlayModifier(content: self, overlay: content(), alignment: alignment)
    }
}

struct OverlayModifier<Content: View, Overlay: View>: TypeSafeView {
    typealias Children = TupleView2<Content, Overlay>.Children

    var body: TupleView2<Content, Overlay>
    var alignment: Alignment

    init(content: Content, overlay: Overlay, alignment: Alignment) {
        body = TupleView2(content, overlay)
        self.alignment = alignment
    }

    func children<Backend: BaseAppBackend>(
        backend: Backend,
        snapshots: [ViewGraphSnapshotter.NodeSnapshot]?,
        environment: EnvironmentValues
    ) -> TupleView2<Content, Overlay>.Children {
        body.children(
            backend: backend,
            snapshots: snapshots,
            environment: environment
        )
    }

    func layoutableChildren<Backend: BaseAppBackend>(
        backend: Backend,
        children: TupleView2<Content, Overlay>.Children
    ) -> [LayoutSystem.LayoutableChild] {
        []
    }

    func asWidget<Backend: BaseAppBackend>(
        _ children: TupleView2<Content, Overlay>.Children,
        backend: Backend
    ) -> Backend.Widget {
        body.asWidget(children, backend: backend)
    }

    func computeLayout<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: TupleView2<Content, Overlay>.Children,
        proposedSize: ProposedViewSize,
        environment: EnvironmentValues,
        backend: Backend
    ) -> ViewLayoutResult {
        let contentResult = children.child0.computeLayout(
            with: body.view0,
            proposedSize: proposedSize,
            environment: environment
        )
        let contentSize = contentResult.size
        let overlayResult = children.child1.computeLayout(
            with: body.view1,
            proposedSize: ProposedViewSize(contentSize),
            environment: environment
        )
        let overlaySize = overlayResult.size

        let size = ViewSize(
            max(contentSize.width, overlaySize.width),
            max(contentSize.height, overlaySize.height)
        )

        // Both children share one line derived from both of them, so an overlay
        // aligned on a guide the two resolve differently lands where each one's
        // own guide actually sits.
        let placements = alignment.placements(
            ofChildren: [contentResult, overlayResult],
            in: size
        )

        // Only the content's guides propagate: an overlay decorates the view
        // it sits on and must not move an ancestor's alignment of it.
        return ViewLayoutResult(
            size: size,
            childResults: [contentResult, overlayResult],
            explicitGuides: ViewLayoutResult.aggregateGuides(
                children: [(contentResult, placements[0])]
            )
        )
    }

    func commit<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: TupleView2<Content, Overlay>.Children,
        layout: ViewLayoutResult,
        environment: EnvironmentValues,
        backend: Backend
    ) {
        let frameSize = layout.size
        let contentResult = children.child0.commit()
        let overlayResult = children.child1.commit()

        let placements = alignment.placements(
            ofChildren: [contentResult, overlayResult],
            in: frameSize
        )

        for (index, placement) in placements.enumerated() {
            backend.setPosition(
                ofChildAt: index,
                in: widget,
                to: SIMD2(
                    LayoutSystem.roundSize(placement.x),
                    LayoutSystem.roundSize(placement.y)
                )
            )
        }

        backend.setSize(of: widget, to: frameSize.vector)
    }
}
