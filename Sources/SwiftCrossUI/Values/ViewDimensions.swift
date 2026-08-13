/// A view's size along with its resolved alignment guides.
///
/// Handed to ``View/alignmentGuide(_:computeValue:)-3v0ny`` closures and to
/// ``AlignmentID/defaultValue(in:)``, so that a guide can be expressed in
/// terms of the view's size or of its other guides.
public struct ViewDimensions {
    /// The view's width.
    public var width: Double
    /// The view's height.
    public var height: Double

    /// The explicit guide values the view reports, in its own coordinate
    /// space. Guides absent from this dictionary resolve to their default.
    var explicitGuides: [AlignmentKey: Double]

    init(size: ViewSize, explicitGuides: [AlignmentKey: Double]) {
        width = size.width
        height = size.height
        self.explicitGuides = explicitGuides
    }

    /// The view's size.
    public var size: ViewSize {
        ViewSize(width, height)
    }

    /// The resolved value of a horizontal guide: the explicit value if the
    /// view sets one, and the alignment's default otherwise.
    ///
    /// - Parameter guide: The alignment whose guide to resolve.
    /// - Returns: The guide's offset from the view's leading edge.
    public subscript(guide: HorizontalAlignment) -> Double {
        self[guide.key]
    }

    /// The resolved value of a vertical guide: the explicit value if the view
    /// sets one, and the alignment's default otherwise.
    ///
    /// - Parameter guide: The alignment whose guide to resolve.
    /// - Returns: The guide's offset from the view's top edge.
    public subscript(guide: VerticalAlignment) -> Double {
        self[guide.key]
    }

    /// The explicit value of a horizontal guide, or `nil` if the view sets
    /// none.
    ///
    /// - Parameter guide: The alignment whose explicit guide to read.
    /// - Returns: The explicit offset from the view's leading edge, if any.
    public subscript(explicit guide: HorizontalAlignment) -> Double? {
        explicitGuides[guide.key]
    }

    /// The explicit value of a vertical guide, or `nil` if the view sets none.
    ///
    /// - Parameter guide: The alignment whose explicit guide to read.
    /// - Returns: The explicit offset from the view's top edge, if any.
    public subscript(explicit guide: VerticalAlignment) -> Double? {
        explicitGuides[guide.key]
    }

    /// The resolved value of a guide identified by its key.
    subscript(key: AlignmentKey) -> Double {
        explicitGuides[key] ?? key.defaultValue(in: self)
    }
}
