/// A type that identifies an alignment guide.
///
/// Conform a type to `AlignmentID` and expose it as a static member of
/// ``HorizontalAlignment`` or ``VerticalAlignment`` to define a custom
/// alignment:
///
/// ```swift
/// enum EventTitleAlignment: AlignmentID {
///     static func defaultValue(in context: ViewDimensions) -> Double {
///         context.height / 2
///     }
/// }
///
/// extension VerticalAlignment {
///     static let eventTitle = VerticalAlignment(EventTitleAlignment.self)
/// }
/// ```
public protocol AlignmentID: Sendable {
    /// The guide value used for a view that sets no explicit guide for this
    /// alignment anywhere in its subtree.
    ///
    /// - Parameter context: The dimensions of the view whose guide is being
    ///   resolved. Other guides of the same view can be read from it, letting
    ///   one guide be defined in terms of another.
    /// - Returns: The offset of the guide from the view's top-leading corner,
    ///   along the alignment's axis.
    static func defaultValue(in context: ViewDimensions) -> Double

    /// Combines the explicit guide values that bubble up from several of a
    /// container's descendants into the single value the container reports.
    ///
    /// The default implementation averages the values, matching SwiftUI.
    ///
    /// - Parameter values: The explicit values, already transformed into the
    ///   reporting container's coordinate space. Never empty.
    /// - Returns: The combined value.
    static func combineExplicit(_ values: [Double]) -> Double
}

extension AlignmentID {
    public static func combineExplicit(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }
}

/// The identity of an alignment guide: the ``AlignmentID`` that defines it
/// paired with the axis it aligns along.
///
/// Guides on different axes never interact, so the axis is part of the
/// identity — a single ``AlignmentID`` used for both a horizontal and a
/// vertical alignment produces two independent guides.
public struct AlignmentKey: Hashable, Sendable {
    /// The axis the guide aligns along.
    public var axis: Axis
    /// The type defining the guide's default value and combining behaviour.
    var id: any AlignmentID.Type

    init(axis: Axis, id: any AlignmentID.Type) {
        self.axis = axis
        self.id = id
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.axis == rhs.axis && lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(axis)
        hasher.combine(ObjectIdentifier(id))
    }

    /// The built-in edge alignment this guide represents, if it is one.
    ///
    /// Backends can only describe the three edge alignments, so a custom guide
    /// has no spelling to hand them.
    var asStackAlignment: StackAlignment? {
        switch axis {
            case .horizontal:
                HorizontalAlignment(id).asStackAlignment
            case .vertical:
                VerticalAlignment(id).asStackAlignment
        }
    }

    /// Resolves the guide for a view that sets no explicit value for it.
    func defaultValue(in context: ViewDimensions) -> Double {
        id.defaultValue(in: context)
    }

    /// Combines explicit values bubbling up from several descendants.
    ///
    /// - Precondition: `values` is non-empty.
    func combineExplicit(_ values: [Double]) -> Double {
        id.combineExplicit(values)
    }
}
