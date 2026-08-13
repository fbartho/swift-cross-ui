/// A container that lays its views on top of each other.
public struct ZStack<Content: View>: View {
    /// The stack's alignment.
    public var alignment: Alignment
    /// The stack's content.
    public var body: Content

    /// Creates a ``ZStack``.
    ///
    /// - Parameters:
    ///   - alignment: The stack's alignment.
    ///   - content: The stack's content.
    public init(
        alignment: Alignment = .center,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            alignment: alignment,
            content: content()
        )
    }

    init(alignment: Alignment, content: Content) {
        self.alignment = alignment
        body = content
    }

    public func asWidget<Backend: BaseAppBackend>(
        _ children: any ViewGraphNodeChildren,
        backend: Backend
    ) -> Backend.Widget {
        let zStack = backend.createContainer()
        for (index, child) in children.widgets(for: backend).enumerated() {
            backend.insert(child, into: zStack, at: index)
        }
        return zStack
    }

    public func computeLayout<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: any ViewGraphNodeChildren,
        proposedSize: ProposedViewSize,
        environment: EnvironmentValues,
        backend: Backend
    ) -> ViewLayoutResult {
        let childResults = layoutableChildren(backend: backend, children: children)
            .map { child in
                child.computeLayout(
                    proposedSize: proposedSize,
                    environment: environment
                )
            }

        let size = Self.frameSize(of: childResults, alignment: alignment)

        if !(children is TupleViewChildren || children is EmptyViewChildren) {
            logger.warning(
                "ZStack will not function correctly with non-TupleView content",
                metadata: [
                    "childrenType": "\(type(of: children))",
                    "contentType": "\(Content.self)",
                ]
            )
        }

        (children as? TupleViewChildren)?.stackLayoutCache = StackLayoutCache(
            priorityGroups: [],
            isHidden: [],
            totalSpacing: 0,
            totalReservedSpace: 0,
            minimumLengths: [],
            redistributeSpaceOnCommit: proposedSize.width == nil || proposedSize.height == nil
        )

        return ViewLayoutResult(
            size: size,
            childResults: childResults,
            explicitGuides: Self.guides(
                of: childResults,
                alignment: alignment,
                in: size
            )
        )
    }

    /// The size a ZStack takes to hold children aligned on the given guides.
    ///
    /// On each axis this is the largest extent on the near side of the shared
    /// guide line plus the largest on the far side, so a child whose guide is
    /// offset from its own box can grow the stack past the largest child. With
    /// no explicit guides it reduces to the largest child on each axis.
    ///
    /// - Parameters:
    ///   - childResults: The children's layout results.
    ///   - alignment: The alignment whose guides the children are placed by.
    /// - Returns: The stack's size.
    static func frameSize(
        of childResults: [ViewLayoutResult],
        alignment: Alignment
    ) -> ViewSize {
        var size = ViewSize.zero
        for (axis, key) in [
            (Axis.horizontal, alignment.horizontal.key),
            (Axis.vertical, alignment.vertical.key),
        ] {
            let line = childResults.map { $0.resolvedGuide(key) }.max() ?? 0
            let beyond =
                childResults.map { child in
                    child.size[component: axis] - child.resolvedGuide(key)
                }.max() ?? 0
            size[component: axis] = line + beyond
        }
        return size
    }

    /// The guides a ZStack reports, aggregated from its children's after
    /// placing each one.
    ///
    /// - Parameters:
    ///   - childResults: The children's layout results.
    ///   - alignment: The alignment whose guides the children are placed by.
    ///   - size: The stack's own size.
    /// - Returns: The stack's guides, in its own coordinate space.
    static func guides(
        of childResults: [ViewLayoutResult],
        alignment: Alignment,
        in size: ViewSize
    ) -> [AlignmentKey: Double] {
        ViewLayoutResult.aggregateGuides(
            children: childResults.map { child in
                let position = alignment.position(ofChild: child, in: size)
                return (child, SIMD2(Double(position.x), Double(position.y)))
            }
        )
    }

    public func commit<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: any ViewGraphNodeChildren,
        layout: ViewLayoutResult,
        environment: EnvironmentValues,
        backend: Backend
    ) {
        let cache = (children as? TupleViewChildren)?.stackLayoutCache ?? StackLayoutCache.initial
        let children = layoutableChildren(backend: backend, children: children)

        if cache.redistributeSpaceOnCommit {
            for child in children {
                _ = child.computeLayout(
                    proposedSize: ProposedViewSize(layout.size),
                    environment: environment
                )
            }
        }

        let size = layout.size
        let layoutResults = children.map { child in
            child.commit()
        }

        for (i, layoutResult) in layoutResults.enumerated() {
            let position = alignment.position(ofChild: layoutResult, in: size)
            backend.setPosition(ofChildAt: i, in: widget, to: position)
        }

        backend.setSize(of: widget, to: size.vector)
    }
}
