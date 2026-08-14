extension View {
    /// Sets this view's guide for a horizontal alignment, overriding both the
    /// alignment's default value and any value bubbling up from this view's
    /// own descendants.
    ///
    /// The value is an offset from this view's leading edge, and containers
    /// aligning on `alignment` will line this view up by it. Values outside
    /// the view's own width are legal, and shift the view further.
    ///
    /// - Parameters:
    ///   - alignment: The alignment whose guide to set.
    ///   - computeValue: Computes the guide from this view's dimensions. Other
    ///     guides of the same view can be read from them, so one guide can be
    ///     written in terms of another.
    /// - Returns: A view reporting the computed guide for `alignment`.
    public func alignmentGuide(
        _ alignment: HorizontalAlignment,
        computeValue: @escaping (ViewDimensions) -> Double
    ) -> some View {
        AlignmentGuideModifier(self, key: alignment.key, computeValue: computeValue)
    }

    /// Sets this view's guide for a vertical alignment, overriding both the
    /// alignment's default value and any value bubbling up from this view's
    /// own descendants.
    ///
    /// The value is an offset from this view's top edge, and containers
    /// aligning on `alignment` will line this view up by it. Values outside
    /// the view's own height are legal, and shift the view further.
    ///
    /// - Parameters:
    ///   - alignment: The alignment whose guide to set.
    ///   - computeValue: Computes the guide from this view's dimensions. Other
    ///     guides of the same view can be read from them, so one guide can be
    ///     written in terms of another.
    /// - Returns: A view reporting the computed guide for `alignment`.
    public func alignmentGuide(
        _ alignment: VerticalAlignment,
        computeValue: @escaping (ViewDimensions) -> Double
    ) -> some View {
        AlignmentGuideModifier(self, key: alignment.key, computeValue: computeValue)
    }
}

/// The implementation for the ``View/alignmentGuide(_:computeValue:)-3v0ny``
/// modifiers.
///
/// Layout-transparent: it takes the child's size unchanged and only rewrites
/// the guide the child reports.
struct AlignmentGuideModifier<Child: View>: TypeSafeView {
    var body: TupleView1<Child>

    /// The guide being set.
    var key: AlignmentKey
    /// Computes the guide's value from the child's dimensions.
    var computeValue: (ViewDimensions) -> Double

    init(
        _ child: Child,
        key: AlignmentKey,
        computeValue: @escaping (ViewDimensions) -> Double
    ) {
        body = TupleView1(child)
        self.key = key
        self.computeValue = computeValue
    }

    func children<Backend: BaseAppBackend>(
        backend: Backend,
        snapshots: [ViewGraphSnapshotter.NodeSnapshot]?,
        environment: EnvironmentValues
    ) -> TupleViewChildren1<Child> {
        body.children(backend: backend, snapshots: snapshots, environment: environment)
    }

    func asWidget<Backend: BaseAppBackend>(
        _ children: TupleViewChildren1<Child>,
        backend: Backend
    ) -> Backend.Widget {
        let container = backend.createContainer()
        backend.insert(children.child0.widget.into(), into: container, at: 0)
        return container
    }

    func computeLayout<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: TupleViewChildren1<Child>,
        proposedSize: ProposedViewSize,
        environment: EnvironmentValues,
        backend: Backend
    ) -> ViewLayoutResult {
        let childResult = children.child0.computeLayout(
            with: body.view0,
            proposedSize: proposedSize,
            environment: environment
        )

        return ViewLayoutResult(
            size: childResult.size,
            childResults: [childResult],
            explicitGuides: guides(from: childResult)
        )
    }

    func commit<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: TupleViewChildren1<Child>,
        layout: ViewLayoutResult,
        environment: EnvironmentValues,
        backend: Backend
    ) {
        _ = children.child0.commit()
        backend.setPosition(ofChildAt: 0, in: widget, to: .zero)
        backend.setSize(of: widget, to: layout.size.vector)
    }

    /// Overrides one guide on the child's reported set.
    ///
    /// Every other guide passes through untouched, so a view can set several
    /// guides by stacking the modifier, and a descendant's guides for other
    /// keys still reach ancestors.
    private func guides(from childResult: ViewLayoutResult) -> [AlignmentKey: Double] {
        var guides = childResult.explicitGuides
        guides[key] = computeValue(childResult.dimensions)
        return guides
    }
}
