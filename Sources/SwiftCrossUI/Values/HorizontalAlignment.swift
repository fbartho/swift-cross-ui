/// Alignment of items layed out along the horizontal axis.
///
/// Extend this type with static members to define custom alignments:
///
/// ```swift
/// extension HorizontalAlignment {
///     static let gutter = HorizontalAlignment(GutterAlignment.self)
/// }
/// ```
public struct HorizontalAlignment: Hashable, Sendable {
    /// Leading alignment (left alignment in left-to-right locales).
    public static let leading = Self(LeadingAlignmentID.self)
    /// Center alignment.
    public static let center = Self(HorizontalCenterAlignmentID.self)
    /// Trailing alignment (right alignment in left-to-right locales).
    public static let trailing = Self(TrailingAlignmentID.self)

    /// The guide this alignment aligns on.
    var key: AlignmentKey

    /// Creates a horizontal alignment from the type identifying its guide.
    ///
    /// - Parameter id: The type defining the guide's default value and, if it
    ///   overrides ``AlignmentID/combineExplicit(_:)``, how values from
    ///   multiple descendants combine.
    public init(_ id: any AlignmentID.Type) {
        key = AlignmentKey(axis: .horizontal, id: id)
    }

    /// The built-in edge alignment this value represents, if it is one.
    ///
    /// Backends and text layout can only express the three edge alignments, so
    /// they need to distinguish them from custom guides.
    @_spi(Backends) public var asEdge: StackAlignmentEdge? {
        switch key.id {
            case is LeadingAlignmentID.Type:
                .leading
            case is HorizontalCenterAlignmentID.Type:
                .center
            case is TrailingAlignmentID.Type:
                .trailing
            default:
                nil
        }
    }

    /// Gets the position of a child of a given width in a frame of a given
    /// width using the alignment.
    ///
    /// Only meaningful for the built-in edge alignments; custom guides resolve
    /// through ``ViewLayoutResult/explicitGuides`` instead, and fall back to
    /// their default value against both frames here.
    ///
    /// - Parameter childWidth: The width of the child.
    /// - Parameter frameWidth: The width of the frame.
    /// - Returns: The position of the child.
    func position(ofChild childWidth: Double, in frameWidth: Double) -> Double {
        let frame = ViewDimensions(size: ViewSize(frameWidth, 0), explicitGuides: [:])
        let child = ViewDimensions(size: ViewSize(childWidth, 0), explicitGuides: [:])
        return frame[key] - child[key]
    }
}

/// The guide backing ``HorizontalAlignment/leading``.
enum LeadingAlignmentID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> Double {
        0
    }
}

/// The guide backing ``HorizontalAlignment/center``.
enum HorizontalCenterAlignmentID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> Double {
        context.width / 2
    }
}

/// The guide backing ``HorizontalAlignment/trailing``.
enum TrailingAlignmentID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> Double {
        context.width
    }
}
