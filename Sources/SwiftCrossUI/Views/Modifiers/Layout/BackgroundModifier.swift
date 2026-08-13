extension View {
    /// Sets the background of this view to another view.
    ///
    /// - Parameter background: The view to place behind this view.
    public func background<Background: View>(_ background: Background) -> some View {
        BackgroundModifier(background: background, foreground: self)
    }

    /// Layers views that you specify behind this view.
    ///
    /// - Parameter alignment: The alignment used to align the implicit ``ZStack``
    ///   the stacks the background views.
    /// - Parameter content: A builder which declares views to display behind this
    ///   view. The builder is implicitly the body of a ``ZStack``, leading to the
    ///   views in the builder stacking in the Z direction.
    public func background<V: View>(
        alignment: Alignment = .center,
        @ViewBuilder content: () -> V
    ) -> some View {
        let zstack = ZStack(alignment: alignment, content: content)
        return BackgroundModifier(background: zstack, foreground: self)
    }
}

struct BackgroundModifier<Background: View, Foreground: View>: TypeSafeView {
    typealias Children = TupleView2<Background, Foreground>.Children

    var body: TupleView2<Background, Foreground>

    init(background: Background, foreground: Foreground) {
        body = TupleView2(background, foreground)
    }

    func children<Backend: BaseAppBackend>(
        backend: Backend,
        snapshots: [ViewGraphSnapshotter.NodeSnapshot]?,
        environment: EnvironmentValues
    ) -> TupleView2<Background, Foreground>.Children {
        body.children(backend: backend, snapshots: snapshots, environment: environment)
    }

    func layoutableChildren<Backend: BaseAppBackend>(
        backend: Backend,
        children: TupleView2<Background, Foreground>.Children
    ) -> [LayoutSystem.LayoutableChild] {
        []
    }

    func asWidget<Backend: BaseAppBackend>(
        _ children: TupleView2<Background, Foreground>.Children,
        backend: Backend
    ) -> Backend.Widget {
        body.asWidget(children, backend: backend)
    }

    func computeLayout<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: TupleView2<Background, Foreground>.Children,
        proposedSize: ProposedViewSize,
        environment: EnvironmentValues,
        backend: Backend
    ) -> ViewLayoutResult {
        let foregroundResult = children.child1.computeLayout(
            with: body.view1,
            proposedSize: proposedSize,
            environment: environment
        )
        let foregroundSize = foregroundResult.size
        let backgroundResult = children.child0.computeLayout(
            with: body.view0,
            proposedSize: ProposedViewSize(foregroundSize),
            environment: environment
        )
        let backgroundSize = backgroundResult.size

        let frameSize = ViewSize(
            max(backgroundSize.width, foregroundSize.width),
            max(backgroundSize.height, foregroundSize.height)
        )

        let placements = Alignment.center.placements(
            ofChildren: [backgroundResult, foregroundResult],
            in: frameSize
        )

        // Only the foreground's guides propagate: a background decorates the
        // view it sits behind and must not move an ancestor's alignment of it.
        // TODO: Investigate the ordering of SwiftUI's preference merging for
        //   the background modifier.
        return ViewLayoutResult(
            size: frameSize,
            childResults: [backgroundResult, foregroundResult],
            explicitGuides: ViewLayoutResult.aggregateGuides(
                children: [(foregroundResult, placements[1])]
            )
        )
    }

    public func commit<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: TupleView2<Background, Foreground>.Children,
        layout: ViewLayoutResult,
        environment: EnvironmentValues,
        backend: Backend
    ) {
        let frameSize = layout.size
        let backgroundResult = children.child0.commit()
        let foregroundResult = children.child1.commit()

        let placements = Alignment.center.placements(
            ofChildren: [backgroundResult, foregroundResult],
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
        backend.describeBackground(of: widget)
    }
}
