import DummyBackend

@testable @_spi(Backends) import SwiftCrossUI

/// The cross-axis placement rule as it stood before alignment guides existed:
/// a three-way switch on the stack's alignment over the container's and the
/// child's sizes, with the container sized to its largest child.
///
/// Kept as an independent implementation rather than a call into the layout
/// system, because its whole job is to disagree if the guide-aware algorithm
/// stops reducing to it.
enum LegacyStackPlacement {
    /// Where the pre-guides algorithm placed a child across a stack's axis.
    ///
    /// - Parameters:
    ///   - childCross: The child's size across the axis.
    ///   - containerCross: The container's size across the axis.
    ///   - alignment: The stack's cross-axis alignment.
    /// - Returns: The child's offset across the axis.
    static func offset(
        childCross: Double,
        containerCross: Double,
        alignment: StackAlignment
    ) -> Double {
        switch alignment {
            case .leading:
                0
            case .center:
                (containerCross - childCross) / 2
            case .trailing:
                containerCross - childCross
        }
    }

    /// The cross size the pre-guides algorithm gave a stack: its largest
    /// child's.
    ///
    /// - Parameter childCrossSizes: The children's sizes across the axis.
    /// - Returns: The container's size across the axis.
    static func containerCross(childCrossSizes: [Double]) -> Double {
        childCrossSizes.max() ?? 0
    }
}

extension LayoutSystem {
    /// Runs the guide-aware cross-axis algorithm and the pre-guides one over
    /// the same children, and reports whether they agree.
    ///
    /// Only meaningful for guide-free children under a built-in alignment,
    /// which is exactly the case the reduction claim covers.
    ///
    /// - Parameters:
    ///   - children: The children's layout results.
    ///   - edge: Which of the three edge alignments the stack uses.
    ///   - orientation: The axis the stack stacks along. The alignment is
    ///     taken on the perpendicular axis, which is the one a stack actually
    ///     aligns across.
    /// - Returns: The two algorithms' cross sizes and per-child offsets.
    static func compareWithLegacyPlacement(
        of children: [ViewLayoutResult],
        edge: StackAlignment,
        orientation: Orientation
    ) -> (
        guideAware: (crossSize: Double, offsets: [Double]),
        legacy: (crossSize: Double, offsets: [Double])
    ) {
        let perpendicular = orientation.perpendicular
        let visible = children.filter(\.participatesInStackLayouts)

        // A stack aligns across its own axis, so a vertical stack takes a
        // horizontal alignment and vice versa. Pairing them the other way
        // would resolve guides against the wrong dimension.
        let key: AlignmentKey =
            switch perpendicular {
                case .horizontal:
                    switch edge {
                        case .leading: HorizontalAlignment.leading.key
                        case .center: HorizontalAlignment.center.key
                        case .trailing: HorizontalAlignment.trailing.key
                    }
                case .vertical:
                    switch edge {
                        case .leading: VerticalAlignment.top.key
                        case .center: VerticalAlignment.center.key
                        case .trailing: VerticalAlignment.bottom.key
                    }
            }

        let geometry = stackCrossGeometry(
            of: children,
            alignment: key,
            orientation: orientation
        )

        let legacyCross = LegacyStackPlacement.containerCross(
            childCrossSizes: visible.map { $0.size[component: perpendicular] }
        )
        let legacyOffsets = children.map { child in
            child.participatesInStackLayouts
                ? LegacyStackPlacement.offset(
                    childCross: child.size[component: perpendicular],
                    containerCross: legacyCross,
                    alignment: edge
                )
                : 0
        }

        return (
            (geometry.crossSize, geometry.offsets),
            (legacyCross, legacyOffsets)
        )
    }
}
