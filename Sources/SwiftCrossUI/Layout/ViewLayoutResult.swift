/// The result of a call to ``View/computeLayout(_:children:proposedSize:environment:backend:)``.
public struct ViewLayoutResult {
    /// The size that the view has chosen for itself based off of the proposed view size.
    public var size: ViewSize
    /// Whether the view participates in stack layouts when empty (i.e. has its own spacing).
    ///
    /// This will be removed once we properly support dynamic alignment and spacing.
    public var participateInStackLayoutsWhenEmpty: Bool
    /// The preference values produced by the view and its children.
    public var preferences: PreferenceValues
    /// The explicit alignment guide values the view reports, expressed in the
    /// view's own coordinate space (origin at its top-leading corner).
    ///
    /// A view reports a guide explicitly when it applies
    /// ``View/alignmentGuide(_:computeValue:)-3v0ny``, or when one of its
    /// descendants does and the value survives propagation up to here. Guides
    /// absent from this dictionary resolve to their ``AlignmentID`` default.
    public var explicitGuides: [AlignmentKey: Double]

    public init(
        size: ViewSize,
        participateInStackLayoutsWhenEmpty: Bool = false,
        preferences: PreferenceValues,
        explicitGuides: [AlignmentKey: Double] = [:]
    ) {
        self.size = size
        self.participateInStackLayoutsWhenEmpty = participateInStackLayoutsWhenEmpty
        self.preferences = preferences
        self.explicitGuides = explicitGuides
    }

    /// Creates a layout result by combining a parent view's sizing and its
    /// children's preference values.
    ///
    /// - Parameters:
    ///   - size: The size the parent chose for itself.
    ///   - childResults: The children's layout results, whose preferences are
    ///     merged into the parent's.
    ///   - participateInStackLayoutsWhenEmpty: Whether the view participates in
    ///     stack layouts when empty.
    ///   - preferencesOverlay: Preferences the parent contributes itself.
    ///   - explicitGuides: The guides the parent reports. Containers build this
    ///     with ``aggregateGuides(children:)`` from their children's guides and
    ///     placements; leaving it empty reports no guides at all, which is only
    ///     correct for views whose children are not laid out inside them.
    public init(
        size: ViewSize,
        childResults: [ViewLayoutResult],
        participateInStackLayoutsWhenEmpty: Bool = false,
        preferencesOverlay: PreferenceValues? = nil,
        explicitGuides: [AlignmentKey: Double] = [:]
    ) {
        self.size = size
        self.participateInStackLayoutsWhenEmpty = participateInStackLayoutsWhenEmpty
        self.explicitGuides = explicitGuides

        preferences = PreferenceValues(
            merging: childResults.map(\.preferences)
                + [preferencesOverlay].compactMap { $0 }
        )
    }

    /// Creates the layout result of a leaf view (one with no children and no
    /// special preference behaviour). Uses ``PreferenceValues/default``.
    public static func leafView(size: ViewSize) -> Self {
        ViewLayoutResult(
            size: size,
            participateInStackLayoutsWhenEmpty: true,
            preferences: .default
        )
    }

    /// Whether the view should participate in stack layouts (i.e. get its own spacing).
    public var participatesInStackLayouts: Bool {
        size != .zero || participateInStackLayoutsWhenEmpty
    }

    /// The view's dimensions: its size plus the guides it reports, ready to
    /// resolve any guide against.
    var dimensions: ViewDimensions {
        ViewDimensions(size: size, explicitGuides: explicitGuides)
    }

    /// Resolves a guide against this result: the explicit value if the view
    /// reports one, and the alignment's default otherwise.
    ///
    /// - Parameter key: The guide to resolve.
    /// - Returns: The guide's offset from the view's top-leading corner along
    ///   the guide's axis.
    func resolvedGuide(_ key: AlignmentKey) -> Double {
        dimensions[key]
    }

    /// Merges the explicit guides of several children into the set their
    /// container reports, transforming each child's guides into the
    /// container's coordinate space first.
    ///
    /// Guides sourced by more than one child are combined with the guide's own
    /// ``AlignmentID/combineExplicit(_:)``, which averages by default.
    ///
    /// - Parameter children: Each child's layout result paired with the
    ///   position the container places it at.
    /// - Returns: The container's explicit guides, in its own coordinate space.
    public static func aggregateGuides(
        children: [(result: ViewLayoutResult, placement: SIMD2<Double>)]
    ) -> [AlignmentKey: Double] {
        var collected: [AlignmentKey: [Double]] = [:]
        for (result, placement) in children {
            for (key, value) in result.explicitGuides {
                let offset = key.axis == .horizontal ? placement.x : placement.y
                collected[key, default: []].append(value + offset)
            }
        }
        return collected.mapValues { key, values in
            key.combineExplicit(values)
        }
    }
}

extension Dictionary {
    /// Maps values with access to each entry's key.
    fileprivate func mapValues<T>(
        _ transform: (Key, Value) -> T
    ) -> [Key: T] {
        var result: [Key: T] = [:]
        result.reserveCapacity(count)
        for (key, value) in self {
            result[key] = transform(key, value)
        }
        return result
    }
}
