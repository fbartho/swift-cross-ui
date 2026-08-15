public enum LayoutSystem {
    static func width(forHeight height: Double, aspectRatio: Double) -> Double {
        Double(height) * aspectRatio
    }

    static func height(forWidth width: Double, aspectRatio: Double) -> Double {
        Double(width) / aspectRatio
    }

    @_spi(Backends) public static func roundSize(_ size: Double) -> Int {
        if size.isInfinite {
            logger.warning("LayoutSystem.roundSize(_:) called with infinite size")
        }

        let size = size.rounded(.up)
        return if size >= Double(Int.max) {
            Int.max
        } else if size <= Double(Int.min) {
            Int.min
        } else {
            Int(size)
        }
    }

    static func clamp(_ value: Double, minimum: Double?, maximum: Double?) -> Double {
        var value = value
        if let minimum {
            value = max(minimum, value)
        }
        if let maximum {
            value = min(maximum, value)
        }
        return value
    }

    static func aspectRatio(of frame: ViewSize) -> Double {
        aspectRatio(of: SIMD2(frame.width, frame.height))
    }

    static func aspectRatio(of frame: SIMD2<Double>) -> Double {
        if frame.x == 0 || frame.y == 0 {
            // Even though we could technically compute an aspect ratio when the
            // ideal width is 0, it leads to a lot of annoying usecases and isn't
            // very meaningful, so we default to 1 in that case as well as the
            // division by zero case.
            return 1
        } else {
            return frame.x / frame.y
        }
    }

    public struct LayoutableChild {
        private var computeLayout:
            @MainActor (
                _ proposedSize: ProposedViewSize,
                _ environment: EnvironmentValues
            ) -> ViewLayoutResult
        private var _commit: @MainActor () -> ViewLayoutResult
        var tag: String?

        public init(
            computeLayout: @escaping @MainActor (ProposedViewSize, EnvironmentValues)
                -> ViewLayoutResult,
            commit: @escaping @MainActor () -> ViewLayoutResult,
            tag: String? = nil
        ) {
            self.computeLayout = computeLayout
            self._commit = commit
            self.tag = tag
        }

        init<Child: View>(
            _ node: AnyViewGraphNode<Child>,
            child: @escaping @Sendable @MainActor () -> Child?
        ) {
            self.init(
                computeLayout: { proposedSize, environment in
                    node.computeLayout(
                        with: child(),
                        proposedSize: proposedSize,
                        environment: environment
                    )
                },
                commit: {
                    node.commit()
                }
            )
        }

        @MainActor
        public func computeLayout(
            proposedSize: ProposedViewSize,
            environment: EnvironmentValues
        ) -> ViewLayoutResult {
            computeLayout(proposedSize, environment)
        }

        @MainActor
        public func commit() -> ViewLayoutResult {
            _commit()
        }
    }

    /// The cross-axis geometry a stack derives from its children's alignment
    /// guides: where each child sits across the axis, and how much room the
    /// stack needs to hold them all.
    struct StackCrossGeometry {
        /// Each child's offset across the stack's axis, indexed as `children`
        /// is. Hidden children get zero.
        var offsets: [Double]
        /// The stack's own extent across its axis: the distance from the
        /// furthest extent above the shared guide line to the furthest below.
        var crossSize: Double
        /// Where the shared guide line sits within the stack, across its axis.
        var guideLine: Double
    }

    /// Places a stack's children across its axis so that every child's
    /// alignment guide falls on one shared line.
    ///
    /// This is the whole cross-axis algorithm, and both phases run it: compute
    /// calls it to size the stack, and commit calls it again after any space
    /// redistribution so the positions it applies match the children's final
    /// sizes rather than the ones compute saw.
    ///
    /// With no explicit guides and a built-in alignment it reduces to the edge
    /// arithmetic it replaces: the guide line lands at
    /// `max(childGuide)`, each offset at `line - childGuide`, and the cross
    /// size at `max(childSize)`.
    ///
    /// - Parameters:
    ///   - children: The children's layout results, in visual order.
    ///   - alignment: The guide the stack aligns on.
    ///   - orientation: The axis the stack stacks along; children are aligned
    ///     across its perpendicular.
    /// - Returns: The children's cross-axis offsets and the stack's cross size.
    static func stackCrossGeometry(
        of children: [ViewLayoutResult],
        alignment: AlignmentKey,
        orientation: Orientation
    ) -> StackCrossGeometry {
        let perpendicular = orientation.perpendicular
        let visible = children.filter(\.participatesInStackLayouts)

        // The shared line sits as far across the axis as the child needing the
        // most room above it, so no child is pushed to a negative offset.
        let guideLine = visible.map { $0.resolvedGuide(alignment) }.max() ?? 0

        // The stack grows to hold the largest extent above the line plus the
        // largest below, which a guide-shifted child can push beyond the size
        // of the tallest child on its own.
        let below =
            visible.map { child in
                child.size[component: perpendicular] - child.resolvedGuide(alignment)
            }.max() ?? 0

        let offsets = children.map { child in
            child.participatesInStackLayouts
                ? guideLine - child.resolvedGuide(alignment)
                : 0
        }

        return StackCrossGeometry(
            offsets: offsets,
            crossSize: guideLine + below,
            guideLine: guideLine
        )
    }

    /// Places a stack's children along and across its axis, and derives the
    /// guides the stack itself reports from theirs.
    ///
    /// Pure in its inputs, so both phases can run it and agree.
    ///
    /// - Parameters:
    ///   - children: The children's layout results, in visual order.
    ///   - alignment: The guide the stack aligns on.
    ///   - orientation: The axis the stack stacks along.
    ///   - spacing: The gap between adjacent visible children.
    /// - Returns: Each child's placement, the stack's cross size, and the
    ///   stack's own explicit guides.
    static func stackPlacements(
        of children: [ViewLayoutResult],
        alignment: AlignmentKey,
        orientation: Orientation,
        spacing: Int
    ) -> (
        placements: [SIMD2<Double>],
        crossSize: Double,
        explicitGuides: [AlignmentKey: Double]
    ) {
        let perpendicular = orientation.perpendicular
        let cross = stackCrossGeometry(
            of: children,
            alignment: alignment,
            orientation: orientation
        )

        var placements = [SIMD2<Double>](repeating: .zero, count: children.count)
        var along = 0.0
        for (index, child) in children.enumerated() {
            guard child.participatesInStackLayouts else {
                continue
            }
            var position = Position.zero
            position[component: orientation] = along
            position[component: perpendicular] = cross.offsets[index]
            placements[index] = SIMD2(position.x, position.y)
            along += child.size[component: orientation] + Double(spacing)
        }

        let guides = ViewLayoutResult.aggregateGuides(
            children: zip(children, placements).map { ($0, $1) }
        )

        return (placements, cross.crossSize, guides)
    }

    /// - Parameter inheritStackLayoutParticipation: If `true`, the stack layout
    ///   will have ``ViewSize/participateInStackLayoutsWhenEmpty`` set to `true`
    ///   if all of its children have it set to true. This allows views such as
    ///   ``Group`` to avoid changing stack layout participation (since ``Group``
    ///   is meant to appear completely invisible to the layout system).
    @MainActor
    static func computeStackLayout<Backend: BaseAppBackend>(
        container: Backend.Widget,
        children: [LayoutableChild],
        cache: inout StackLayoutCache,
        proposedSize: ProposedViewSize,
        environment: EnvironmentValues,
        backend: Backend,
        inheritStackLayoutParticipation: Bool = false
    ) -> ViewLayoutResult {
        let spacing = environment.layoutSpacing
        let orientation = environment.layoutOrientation
        let perpendicularOrientation = orientation.perpendicular

        let stackLength = proposedSize[component: orientation]
        if stackLength == 0 || stackLength == .infinity || stackLength == nil || children.count == 1
        {
            var resultLength: Double = 0
            var results: [ViewLayoutResult] = []
            for child in children {
                let result = child.computeLayout(
                    proposedSize: proposedSize,
                    environment: environment
                )
                resultLength += result.size[component: orientation]
                results.append(result)
            }

            let visibleChildrenCount = results.count { result in
                result.participatesInStackLayouts
            }

            let placement = stackPlacements(
                of: results,
                alignment: environment.layoutAlignment,
                orientation: orientation,
                spacing: spacing
            )

            let totalSpacing = Double(max(visibleChildrenCount - 1, 0) * spacing)
            var size = ViewSize.zero
            size[component: orientation] = resultLength + totalSpacing
            size[component: perpendicularOrientation] = placement.crossSize

            // In this case, flexibility and layout priority don't matter. We set
            // the grouping to the trivial grouping so that commitStackLayout
            // effectively ignores flexibility.
            let group = LayoutPriorityGroup(
                children: Array(children.indices)[...],
                priority: 0
            )
            cache = StackLayoutCache(
                priorityGroups: [group],
                isHidden: results.map(\.participatesInStackLayouts).map(!),
                // TODO(stackotter): How does SwiftUI handle space reservation during
                //   relayouts? I feel like it probably doesn't use minimum lengths if
                //   it didn't already have to during the initial layout pass because
                //   the alternative would be expensive, but that approach would also
                //   be a bit inconsistent
                totalSpacing: totalSpacing,
                totalReservedSpace: totalSpacing,
                minimumLengths: [Double](repeating: 0, count: children.count),
                maximumLengths: results.map { $0.size[component: orientation] },
                redistributeSpaceOnCommit: shouldRedistributeSpaceOnCommit(
                    proposedSize: proposedSize,
                    orientation: orientation
                )
            )

            return ViewLayoutResult(
                size: size,
                childResults: results,
                participateInStackLayoutsWhenEmpty: results
                    .contains(where: \.participateInStackLayoutsWhenEmpty),
                preferencesOverlay: nil,
                explicitGuides: placement.explicitGuides
            )
        }

        guard let stackLength else {
            fatalError("unreachable")
        }

        cache = recomputeCache(
            children: children,
            proposedSize: proposedSize,
            environment: environment
        )

        let renderedChildren = computeLayouts(
            of: children,
            proposedLength: stackLength,
            proposedPerpendicular: proposedSize[component: perpendicularOrientation],
            cache: cache,
            environment: environment,
            ignoreHiddenChildrenEntirely: false
        )

        let placement = stackPlacements(
            of: renderedChildren,
            alignment: environment.layoutAlignment,
            orientation: orientation,
            spacing: spacing
        )

        var size = ViewSize.zero
        size[component: orientation] =
            renderedChildren.map(\.size[component: orientation]).reduce(0, +) + cache.totalSpacing
        size[component: perpendicularOrientation] = placement.crossSize

        return ViewLayoutResult(
            size: size,
            childResults: renderedChildren,
            participateInStackLayoutsWhenEmpty: renderedChildren
                .contains(where: \.participateInStackLayoutsWhenEmpty),
            explicitGuides: placement.explicitGuides
        )
    }

    /// Computes whether or not we have to redistribute space on commit. Returns true
    /// if and only if the perpendicular component of the proposed size is nil.
    static func shouldRedistributeSpaceOnCommit(
        proposedSize: ProposedViewSize,
        orientation: Orientation
    ) -> Bool {
        // When the perpendicular axis is unspecified (nil), we need
        // to re-run the space distribution algorithm with our final size during
        // the commit phase. This opens the door to certain edge cases, but SwiftUI
        // has them too, and there's not a good general solution to these edge
        // cases, even if you assume that you have unlimited compute. The reason for
        // this distribution is so that flexible children get a chance to use up any
        // unused space within the final perpendicular size of the stack.
        proposedSize[component: orientation.perpendicular] == nil
    }

    /// Computes the cache from scratch for the slow path (this is our last
    /// resort if shortcuts can't be made), preparing it for subsequent layout
    /// operations.
    @MainActor
    static func recomputeCache(
        children: [LayoutableChild],
        proposedSize: ProposedViewSize,
        environment: EnvironmentValues
    ) -> StackLayoutCache {
        let orientation = environment.layoutOrientation
        let spacing = environment.layoutSpacing

        // My thanks go to this great article for investigating and explaining
        // how SwiftUI determines child view 'flexibility':
        // https://www.objc.io/blog/2020/11/10/hstacks-child-ordering/
        var minimumProposedSize = proposedSize
        minimumProposedSize[component: orientation] = 0
        var maximumProposedSize = proposedSize
        maximumProposedSize[component: orientation] = .infinity
        var isHidden = [Bool](repeating: false, count: children.count)
        var priorities = [Double](repeating: 0, count: children.count)
        var minimums = [Double](repeating: 0, count: children.count)
        var maximums = [Double](repeating: 0, count: children.count)
        var totalReservedSpace = 0.0
        let flexibilities = children.enumerated().map { i, child in
            let minimumResult = child.computeLayout(
                proposedSize: minimumProposedSize,
                environment: environment.with(\.allowLayoutCaching, true)
            )
            let maximumResult = child.computeLayout(
                proposedSize: maximumProposedSize,
                environment: environment.with(\.allowLayoutCaching, true)
            )
            isHidden[i] = !minimumResult.participatesInStackLayouts
            priorities[i] = minimumResult.preferences.layoutPriority
            let maximum = maximumResult.size[component: orientation]
            let minimum = minimumResult.size[component: orientation]
            totalReservedSpace += minimum
            minimums[i] = minimum
            maximums[i] = maximum
            return maximum - minimum
        }
        let visibleChildrenCount = isHidden.filter { hidden in
            !hidden
        }.count
        let totalSpacing = Double(max(visibleChildrenCount - 1, 0) * spacing)
        totalReservedSpace += totalSpacing

        let sortedChildren = zip(children.indices, zip(priorities.map(-), flexibilities))
            .sorted { first, second in
                // Sort by descending priority and then by ascending flexibility
                first.1 <= second.1
            }
            .map { index, _ in
                index
            }

        var priorityGroups: [LayoutPriorityGroup] = []
        var previousPriority: Double? = nil
        var startIndex: Int?
        for (sortedIndex, originalIndex) in sortedChildren.enumerated() {
            let priority = priorities[originalIndex]
            if priority != previousPriority {
                if let startIndex, let previousPriority {
                    let group = LayoutPriorityGroup(
                        children: sortedChildren[startIndex..<sortedIndex],
                        priority: previousPriority
                    )
                    priorityGroups.append(group)
                }
                startIndex = sortedIndex
                previousPriority = priority
            }
        }

        if let startIndex, let previousPriority {
            let group = LayoutPriorityGroup(
                children: sortedChildren[startIndex..<sortedChildren.endIndex],
                priority: previousPriority
            )
            priorityGroups.append(group)
        }

        return StackLayoutCache(
            priorityGroups: priorityGroups,
            isHidden: isHidden,
            totalSpacing: totalSpacing,
            totalReservedSpace: totalReservedSpace,
            minimumLengths: minimums,
            maximumLengths: maximums,
            redistributeSpaceOnCommit: shouldRedistributeSpaceOnCommit(
                proposedSize: proposedSize,
                orientation: orientation
            )
        )
    }

    @MainActor
    static func commitStackLayout<Backend: BaseAppBackend>(
        container: Backend.Widget,
        children: [LayoutableChild],
        cache: inout StackLayoutCache,
        layout: ViewLayoutResult,
        environment: EnvironmentValues,
        backend: Backend
    ) {
        let size = layout.size
        backend.setSize(of: container, to: size.vector)

        let alignment = environment.layoutAlignment
        let spacing = environment.layoutSpacing
        let orientation = environment.layoutOrientation
        let perpendicularOrientation = orientation.perpendicular

        backend.describeStackLayout(
            of: container,
            orientation: orientation,
            alignment: alignment.description(
                slackFraction: alignmentSlackFraction(alignment)
            ),
            spacing: spacing
        )

        // priorityGroups is grouped and reordered by flexibility, not indexed
        // by visual position, so it's unwound back into one priority per
        // child here — the shape every other per-child backend call
        // (setPosition, swap) already uses — rather than making backends
        // redo that unwinding themselves.
        var priorities = [Double](repeating: 0, count: children.count)
        for group in cache.priorityGroups {
            for index in group.children {
                priorities[index] = group.priority
            }
        }
        backend.describeChildLayoutPriorities(of: container, priorities: priorities)

        // Guarded because ZStack and a cache that never ran a layout pass
        // (``StackLayoutCache/initial``) carry no per-child endpoints at
        // all, and a backend indexing these by child would read past the
        // end.
        if cache.minimumLengths.count == children.count,
           cache.maximumLengths.count == children.count
        {
            backend.describeChildFlexibility(
                of: container,
                minimums: cache.minimumLengths,
                maximums: cache.maximumLengths
            )
        }

        if cache.redistributeSpaceOnCommit {
            _ = computeLayouts(
                of: children,
                proposedLength: layout.size[component: orientation],
                proposedPerpendicular: layout.size[component: perpendicularOrientation],
                cache: cache,
                environment: environment,
                ignoreHiddenChildrenEntirely: true
            )
        }

        let renderedChildren = children.map { $0.commit() }

        // Re-derived rather than carried over from compute: redistribution may
        // have changed the children's sizes, and a guide is a function of the
        // size it was resolved against.
        let placement = stackPlacements(
            of: renderedChildren,
            alignment: alignment,
            orientation: orientation,
            spacing: spacing
        )

        // The stack keeps the cross size it promised its parent at compute
        // time; the guide line re-centres within it so that a redistribution
        // that shrank a child doesn't leave the line where nothing sits.
        let crossSlack =
            size[component: perpendicularOrientation] - placement.crossSize

        for (index, child) in renderedChildren.enumerated() {
            // Avoid the whole iteration if the child is hidden. If there
            // are weird positioning issues for views that do strange things
            // then this could be the cause.
            if !child.participatesInStackLayouts {
                continue
            }

            var position = Position(placement.placements[index].x, placement.placements[index].y)
            position[component: perpendicularOrientation] +=
                crossSlack * alignmentSlackFraction(alignment)

            backend.setPosition(ofChildAt: index, in: container, to: position.vector)
        }
    }

    /// How a stack distributes cross-axis slack between the space above its
    /// guide line and the space below, when its committed cross size exceeds
    /// what its children need.
    ///
    /// Leading pins to the near edge, trailing to the far edge, and center
    /// splits the difference. A custom guide has no edge to pin to, so it
    /// splits like center.
    static func alignmentSlackFraction(_ alignment: AlignmentKey) -> Double {
        let unit = ViewDimensions(size: ViewSize(1, 1), explicitGuides: [:])
        // A guide's default value at unit size is exactly the fraction of the
        // view that sits above the line, which is the fraction of the slack
        // that belongs above it.
        return alignment.defaultValue(in: unit)
    }

    /// The main stack layout space allocation algorithm. Used during
    /// computeLayout, and sometimes during commit when we have to redistribute
    /// space (due to an unspecified perpendicular size proposal).
    @MainActor
    static func computeLayouts(
        of children: [LayoutableChild],
        proposedLength: Double,
        proposedPerpendicular: Double?,
        cache: StackLayoutCache,
        environment: EnvironmentValues,
        ignoreHiddenChildrenEntirely: Bool
    ) -> [ViewLayoutResult] {
        var renderedChildren = [ViewLayoutResult](
            repeating: .leafView(size: .zero),
            count: children.count
        )

        let orientation = environment.layoutOrientation
        let perpendicularOrientation = orientation.perpendicular
        var spaceUsedAlongStackAxis = 0.0
        var reservedSpace = cache.totalReservedSpace
        for group in cache.priorityGroups {
            var childrenRemaining = group.children.count { index in
                !cache.isHidden[index]
            }

            for index in group.children {
                let child = children[index]

                // No need to render visible children.
                if cache.isHidden[index] {
                    if ignoreHiddenChildrenEntirely {
                        continue
                    }

                    // Update child in case it has just changed from visible to hidden,
                    // and to make sure that the view is still hidden (if it's not then
                    // it's a bug with either the view or the layout system).
                    let result = child.computeLayout(
                        proposedSize: .zero,
                        environment: environment
                    )
                    if result.participatesInStackLayouts {
                        logger.warning(
                            "hidden view became visible on second update; layout may break",
                            metadata: [
                                "view": "\(child.tag ?? "<unknown type>")"
                            ]
                        )
                    }
                    renderedChildren[index] = result
                    renderedChildren[index].participateInStackLayoutsWhenEmpty = false
                    renderedChildren[index].size = .zero
                    continue
                }

                reservedSpace -= cache.minimumLengths[index]

                var proposedChildSize = ProposedViewSize.unspecified
                proposedChildSize[component: orientation] = max(
                    proposedLength - spaceUsedAlongStackAxis - reservedSpace,
                    0
                ) / Double(childrenRemaining)
                proposedChildSize[component: perpendicularOrientation] = proposedPerpendicular

                let childResult = child.computeLayout(
                    proposedSize: proposedChildSize,
                    environment: environment
                )

                renderedChildren[index] = childResult
                childrenRemaining -= 1

                spaceUsedAlongStackAxis += childResult.size[component: orientation]
            }
        }

        return renderedChildren
    }
}
