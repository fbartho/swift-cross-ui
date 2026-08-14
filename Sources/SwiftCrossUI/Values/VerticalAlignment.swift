/// Alignment of items layed out along the vertical axis.
///
/// Extend this type with static members to define custom alignments:
///
/// ```swift
/// extension VerticalAlignment {
///     static let eventTitle = VerticalAlignment(EventTitleAlignment.self)
/// }
/// ```
public struct VerticalAlignment: Hashable, Sendable {
    /// Top alignment.
    public static let top = Self(TopAlignmentID.self)
    /// Center alignment.
    public static let center = Self(VerticalCenterAlignmentID.self)
    /// Bottom alignment.
    public static let bottom = Self(BottomAlignmentID.self)
    /// Alignment on the baseline of a view's first line of text.
    ///
    /// A view with no text in it reports its bottom edge, so that it sits on
    /// the line the text sits on. Where several of a container's descendants
    /// report a first baseline, the topmost wins.
    public static let firstTextBaseline = Self(FirstTextBaselineAlignmentID.self)
    /// Alignment on the baseline of a view's last line of text.
    ///
    /// A view with no text in it reports its bottom edge. Where several of a
    /// container's descendants report a last baseline, the bottommost wins.
    public static let lastTextBaseline = Self(LastTextBaselineAlignmentID.self)

    /// The guide this alignment aligns on.
    var key: AlignmentKey

    /// Creates a vertical alignment from the type identifying its guide.
    ///
    /// - Parameter id: The type defining the guide's default value and, if it
    ///   overrides ``AlignmentID/combineExplicit(_:)``, how values from
    ///   multiple descendants combine.
    public init(_ id: any AlignmentID.Type) {
        key = AlignmentKey(axis: .vertical, id: id)
    }

    /// The built-in edge alignment this value represents, if it is one.
    ///
    /// Backends can only express the three edge alignments, so they need to
    /// distinguish them from custom guides.
    var asEdge: StackAlignmentEdge? {
        switch key.id {
            case is TopAlignmentID.Type:
                .leading
            case is VerticalCenterAlignmentID.Type:
                .center
            case is BottomAlignmentID.Type:
                .trailing
            default:
                nil
        }
    }

    /// Gets the position of a child of a given height in a frame of a given
    /// height using the alignment.
    ///
    /// Only meaningful for the built-in edge alignments; custom guides resolve
    /// through ``ViewLayoutResult/explicitGuides`` instead, and fall back to
    /// their default value against both frames here.
    ///
    /// - Parameter childHeight: The height of the child.
    /// - Parameter frameHeight: The height of the frame.
    /// - Returns: The position of the child.
    func position(ofChild childHeight: Double, in frameHeight: Double) -> Double {
        let frame = ViewDimensions(size: ViewSize(0, frameHeight), explicitGuides: [:])
        let child = ViewDimensions(size: ViewSize(0, childHeight), explicitGuides: [:])
        return frame[key] - child[key]
    }
}

/// The guide backing ``VerticalAlignment/top``.
enum TopAlignmentID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> Double {
        0
    }
}

/// The guide backing ``VerticalAlignment/center``.
enum VerticalCenterAlignmentID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> Double {
        context.height / 2
    }
}

/// The guide backing ``VerticalAlignment/bottom``.
enum BottomAlignmentID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> Double {
        context.height
    }
}

/// The guide backing ``VerticalAlignment/firstTextBaseline``.
///
/// ``Text`` sets this explicitly from its backend's font metrics; everything
/// else falls back to its bottom edge, which is where a non-text view sits
/// relative to text it is aligned with.
enum FirstTextBaselineAlignmentID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> Double {
        context.height
    }

    /// The topmost baseline wins, so a container's first baseline is the first
    /// baseline of its text however deep it sits.
    static func combineExplicit(_ values: [Double]) -> Double {
        values.min() ?? 0
    }
}

/// The guide backing ``VerticalAlignment/lastTextBaseline``.
enum LastTextBaselineAlignmentID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> Double {
        context.height
    }

    /// The bottommost baseline wins, mirroring
    /// ``FirstTextBaselineAlignmentID``.
    static func combineExplicit(_ values: [Double]) -> Double {
        values.max() ?? 0
    }
}
