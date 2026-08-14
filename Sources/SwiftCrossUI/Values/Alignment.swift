/// The 2D alignment of a view.
public struct Alignment: Hashable, Sendable {
    /// Centered in both dimensions.
    public static let center = Self(horizontal: .center, vertical: .center)

    /// Touching the top and leading edges.
    public static let topLeading = Self(horizontal: .leading, vertical: .top)
    /// Centered along the top edge.
    public static let top = Self(horizontal: .center, vertical: .top)
    /// Touching the top and trailing edges.
    public static let topTrailing = Self(horizontal: .trailing, vertical: .top)

    /// Touching the bottom and leading edges.
    public static let bottomLeading = Self(horizontal: .leading, vertical: .bottom)
    /// Centered along the bottom edge.
    public static let bottom = Self(horizontal: .center, vertical: .bottom)
    /// Touching the bottom and trailing edges.
    public static let bottomTrailing = Self(horizontal: .trailing, vertical: .bottom)

    /// Centered along the leading edge.
    public static let leading = Self(horizontal: .leading, vertical: .center)
    /// Centered along the trailing edge.
    public static let trailing = Self(horizontal: .trailing, vertical: .center)

    /// Aligned to the leading edge and the first text baseline.
    public static let leadingFirstTextBaseline = Self(
        horizontal: .leading,
        vertical: .firstTextBaseline
    )
    /// Centered horizontally and aligned to the first text baseline.
    public static let centerFirstTextBaseline = Self(
        horizontal: .center,
        vertical: .firstTextBaseline
    )
    /// Aligned to the trailing edge and the first text baseline.
    public static let trailingFirstTextBaseline = Self(
        horizontal: .trailing,
        vertical: .firstTextBaseline
    )

    /// Aligned to the leading edge and the last text baseline.
    public static let leadingLastTextBaseline = Self(
        horizontal: .leading,
        vertical: .lastTextBaseline
    )
    /// Centered horizontally and aligned to the last text baseline.
    public static let centerLastTextBaseline = Self(
        horizontal: .center,
        vertical: .lastTextBaseline
    )
    /// Aligned to the trailing edge and the last text baseline.
    public static let trailingLastTextBaseline = Self(
        horizontal: .trailing,
        vertical: .lastTextBaseline
    )

    /// The horizontal alignment component.
    public var horizontal: HorizontalAlignment
    /// The vertical alignment component.
    public var vertical: VerticalAlignment

    /// Creates a custom alignment with the given horizontal and vertical
    /// components.
    ///
    /// - Parameters:
    ///   - horizontal: The horizontal alignment component.
    ///   - vertical: The vertical alignment component.
    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    /// Computes the position of a child in a parent view using the provided
    /// sizes.
    ///
    /// - Parameters:
    ///   - child: The size of the child, as a width/height vector.
    ///   - parent: The size of the parent, as a width/height vector.
    /// - Returns: The position of the child within the parent, as an x/y
    ///   vector.
    public func position(
        ofChild child: SIMD2<Int>,
        in parent: SIMD2<Int>
    ) -> SIMD2<Int> {
        position(
            ofChild: ViewLayoutResult.leafView(size: ViewSize(child)),
            in: ViewSize(parent)
        )
    }

    /// Where a set of children sit inside a container of a given size, so that
    /// every child's guide for this alignment falls on one shared line per
    /// axis.
    ///
    /// The line is this alignment's default at the container's own size: that
    /// is what puts a child on the container's edge or centre, and what makes
    /// an explicit guide on a child shift it relative to the container the way
    /// setting a guide is meant to.
    ///
    /// Where several children source the same guide explicitly, the line is
    /// pushed later — never earlier — far enough that none of them lands at a
    /// negative offset outside the container. A single child can't need that:
    /// its own guide is the line by definition. Children that merely resolve
    /// the guide to its default don't move the line.
    ///
    /// - Parameters:
    ///   - children: The children's layout results.
    ///   - container: The container's own size.
    /// - Returns: Each child's placement, in child order.
    func placements(
        ofChildren children: [ViewLayoutResult],
        in container: ViewSize
    ) -> [SIMD2<Double>] {
        let containerDimensions = ViewDimensions(size: container, explicitGuides: [:])
        var placements = [SIMD2<Double>](repeating: .zero, count: children.count)

        for (axis, key) in [
            (Axis.horizontal, horizontal.key),
            (Axis.vertical, vertical.key),
        ] {
            let containerLine = containerDimensions[key]
            // Only children actually sourcing the guide can move the line, and
            // only by as far as they would otherwise overhang the container.
            let overhang = children.compactMap { child in
                child.explicitGuides[key].map { $0 - containerLine }
            }.max() ?? 0
            let line = containerLine + max(overhang, 0)

            for (index, child) in children.enumerated() {
                let offset = line - child.resolvedGuide(key)
                if axis == .horizontal {
                    placements[index].x = offset
                } else {
                    placements[index].y = offset
                }
            }
        }
        return placements
    }

    /// Where one child sits inside a container, honouring the guides it
    /// reports.
    ///
    /// - Parameters:
    ///   - child: The child's layout result.
    ///   - parent: The size of the parent.
    /// - Returns: The position of the child within the parent, as an x/y
    ///   vector.
    func position(
        ofChild child: ViewLayoutResult,
        in parent: ViewSize
    ) -> SIMD2<Int> {
        let placement = placements(ofChildren: [child], in: parent)[0]
        return SIMD2(
            LayoutSystem.roundSize(placement.x),
            LayoutSystem.roundSize(placement.y)
        )
    }

    /// Where a shared guide line sits across a set of children on one axis, and
    /// how far past it they reach.
    ///
    /// The line sits at the largest guide among the children, so no child is
    /// pushed to a negative offset; the extent beyond is the largest remaining
    /// distance to a child's far edge. Their sum is the size a container needs
    /// on that axis, which with no explicit guides is just the largest child.
    ///
    /// - Parameters:
    ///   - children: The children's layout results.
    ///   - key: The guide the children are aligned by.
    ///   - axis: The axis being resolved.
    /// - Returns: The line's offset and the extent beyond it.
    static func guideLine(
        of children: [ViewLayoutResult],
        key: AlignmentKey,
        axis: Axis
    ) -> (line: Double, beyond: Double) {
        let line = children.map { $0.resolvedGuide(key) }.max() ?? 0
        let beyond =
            children.map { child in
                child.size[component: axis] - child.resolvedGuide(key)
            }.max() ?? 0
        return (line, beyond)
    }

    /// Where a set of children sit inside a container that sized itself to hold
    /// them, so that every child's guide falls on one shared line per axis.
    ///
    /// Unlike ``placements(ofChildren:in:)``, the line comes from the children
    /// alone: a container sized by ``frameSize(ofChildren:)`` has no size of
    /// its own to resolve a default against that its children didn't already
    /// determine. Any slack between the committed size and what the children
    /// need is distributed the way the alignment's default would distribute it,
    /// which keeps the built-in edge alignments pinned to their edges.
    ///
    /// - Parameters:
    ///   - children: The children's layout results.
    ///   - container: The container's committed size.
    /// - Returns: Each child's placement, in child order.
    func placements(
        ofDerivedChildren children: [ViewLayoutResult],
        in container: ViewSize
    ) -> [SIMD2<Double>] {
        var placements = [SIMD2<Double>](repeating: .zero, count: children.count)
        for (axis, key) in [
            (Axis.horizontal, horizontal.key),
            (Axis.vertical, vertical.key),
        ] {
            let needed = Self.guideLine(of: children, key: key, axis: axis)
            let slack = container[component: axis] - (needed.line + needed.beyond)
            let line = needed.line + slack * LayoutSystem.alignmentSlackFraction(key)

            for (index, child) in children.enumerated() {
                let offset = line - child.resolvedGuide(key)
                if axis == .horizontal {
                    placements[index].x = offset
                } else {
                    placements[index].y = offset
                }
            }
        }
        return placements
    }

    /// The size a container takes to hold children aligned on this alignment's
    /// guides.
    ///
    /// - Parameter children: The children's layout results.
    /// - Returns: The container's size.
    func frameSize(ofChildren children: [ViewLayoutResult]) -> ViewSize {
        var size = ViewSize.zero
        for (axis, key) in [
            (Axis.horizontal, horizontal.key),
            (Axis.vertical, vertical.key),
        ] {
            let resolved = Self.guideLine(of: children, key: key, axis: axis)
            size[component: axis] = resolved.line + resolved.beyond
        }
        return size
    }
}
