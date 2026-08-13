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

    /// Where a ZStack's shared guide line sits on one axis, and how far the
    /// children reach beyond it.
    ///
    /// The line sits at the largest guide among the children, so no child is
    /// pushed to a negative offset; the extent beyond is the largest remaining
    /// distance to a child's far edge. Their sum is the stack's size on that
    /// axis, which with no explicit guides is just the largest child.
    ///
    /// - Parameters:
    ///   - childResults: The children's layout results.
    ///   - key: The guide the children are aligned by.
    ///   - axis: The axis being resolved.
    /// - Returns: The line's offset and the extent beyond it.
    static func guideLine(
        of childResults: [ViewLayoutResult],
        key: AlignmentKey,
        axis: Axis
    ) -> (line: Double, beyond: Double) {
        let line = childResults.map { $0.resolvedGuide(key) }.max() ?? 0
        let beyond =
            childResults.map { child in
                child.size[component: axis] - child.resolvedGuide(key)
            }.max() ?? 0
        return (line, beyond)
    }

    /// The size a ZStack takes to hold children aligned on the given guides.
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
            let resolved = guideLine(of: childResults, key: key, axis: axis)
            size[component: axis] = resolved.line + resolved.beyond
        }
        return size
    }

    /// Where a ZStack places each child, so that every child's guide falls on
    /// the shared line.
    ///
    /// Resolved against the children's own guides rather than through
    /// ``Alignment/position(ofChild:in:)``, because the line is where the
    /// children put it — the stack's own default value for the guide would
    /// place them somewhere nothing agreed on, and can push a child to a
    /// negative offset.
    ///
    /// - Parameters:
    ///   - childResults: The children's layout results.
    ///   - alignment: The alignment whose guides the children are placed by.
    ///   - size: The stack's own size.
    /// - Returns: Each child's placement, in child order.
    static func placements(
        of childResults: [ViewLayoutResult],
        alignment: Alignment,
        in size: ViewSize
    ) -> [SIMD2<Double>] {
        var placements = [SIMD2<Double>](repeating: .zero, count: childResults.count)
        for (axis, key) in [
            (Axis.horizontal, alignment.horizontal.key),
            (Axis.vertical, alignment.vertical.key),
        ] {
            let needed = guideLine(of: childResults, key: key, axis: axis)
            // Any slack between the stack's committed size and what the
            // children need is distributed the way the alignment's own default
            // would distribute it, which keeps the built-in edge alignments
            // pinned to their edges.
            let slack = size[component: axis] - (needed.line + needed.beyond)
            let shift = needed.line + slack * LayoutSystem.alignmentSlackFraction(key)
            for (index, child) in childResults.enumerated() {
                let offset = shift - child.resolvedGuide(key)
                if axis == .horizontal {
                    placements[index].x = offset
                } else {
                    placements[index].y = offset
                }
            }
        }
        return placements
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
                zip(childResults, placements(of: childResults, alignment: alignment, in: size))
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
        let placements = Self.placements(of: layoutResults, alignment: alignment, in: size)
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
