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

        let size = alignment.frameSize(ofChildren: childResults)

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
            maximumLengths: [],
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
            children: Array(
                zip(
                    childResults,
                    alignment.placements(ofDerivedChildren: childResults, in: size)
                )
            )
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

        // Re-derived from the committed sizes rather than reused from compute,
        // for the same reason the axis stacks re-derive theirs: a redistribution
        // pass may have resized children, and a guide is a function of the size
        // it resolved against.
        let placements = alignment.placements(ofDerivedChildren: layoutResults, in: size)
        for (i, placement) in placements.enumerated() {
            backend.setPosition(
                ofChildAt: i,
                in: widget,
                to: SIMD2(
                    LayoutSystem.roundSize(placement.x),
                    LayoutSystem.roundSize(placement.y)
                )
            )
        }

        backend.setSize(of: widget, to: size.vector)
    }
}
