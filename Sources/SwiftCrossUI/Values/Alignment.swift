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

    /// Computes the position of a child in a parent view, honouring any
    /// explicit alignment guides the child reports.
    ///
    /// - Parameters:
    ///   - child: The child's layout result, whose explicit guides override
    ///     this alignment's defaults on either axis.
    ///   - parent: The size of the parent.
    /// - Returns: The position of the child within the parent, as an x/y
    ///   vector.
    func position(
        ofChild child: ViewLayoutResult,
        in parent: ViewSize
    ) -> SIMD2<Int> {
        let parentDimensions = ViewDimensions(size: parent, explicitGuides: [:])
        let childDimensions = child.dimensions
        let x = parentDimensions[horizontal] - childDimensions[horizontal]
        let y = parentDimensions[vertical] - childDimensions[vertical]
        return SIMD2(LayoutSystem.roundSize(x), LayoutSystem.roundSize(y))
    }
}
