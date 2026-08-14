/// How a stack aligned its children across its axis, described for a backend
/// that re-expresses the layout in a system with its own flow rules.
///
/// A backend that positions children itself never needs this — the committed
/// positions already say where everything went. One that hands the arrangement
/// to another layout system does, and the two cases it has to tell apart are
/// not interchangeable: an edge alignment names a line that system can express
/// directly, while a custom guide names a line only SwiftCrossUI can resolve,
/// because its value comes from running an author's closure against geometry.
///
/// Describing a custom guide as the nearest edge would be a lie a backend
/// couldn't detect, so the two are separate cases and the guide carries what a
/// backend needs to fall back honestly.
public enum StackAlignmentDescription: Hashable, Sendable {
    /// Alignment on one of the three built-in edges of the stack's cross axis.
    ///
    /// - Parameter edge: Which edge the children were aligned to.
    case edge(StackAlignmentEdge)

    /// Alignment on a custom guide, which resolves per-child against each
    /// child's own geometry and so has no fixed position a backend can name.
    ///
    /// - Parameters:
    ///   - key: The guide the stack aligned on, for a backend that can
    ///     serialise the alignment as a reference for a runtime to resolve
    ///     against real geometry.
    ///   - slackFraction: Where the guide line sits within the stack's cross
    ///     axis when the stack has slack to distribute, as a fraction from the
    ///     leading edge — the guide's default value at unit size. A backend
    ///     with no way to resolve the guide itself can approximate it as the
    ///     closest edge or centre from this.
    case guide(key: AlignmentKey, slackFraction: Double)

    /// The edge that sits closest to where this alignment puts the guide line.
    ///
    /// The honest fallback for a backend that can only express the three
    /// edges: an edge alignment is itself, and a custom guide becomes whichever
    /// edge its slack fraction is nearest — approximate by construction, which
    /// is why it has to be asked for rather than being what the description
    /// says in the first place.
    public var closestEdge: StackAlignmentEdge {
        switch self {
            case .edge(let edge):
                edge
            case .guide(_, let slackFraction):
                if slackFraction < 0.25 {
                    .leading
                } else if slackFraction > 0.75 {
                    .trailing
                } else {
                    .center
                }
        }
    }
}

/// One of the three built-in edges a stack can align its children to across
/// its axis.
public enum StackAlignmentEdge: Hashable, Sendable {
    /// Leading alignment (left/top for left-to-right locales).
    case leading
    /// Center alignment.
    case center
    /// Trailing alignment (right/bottom for left-to-right locales).
    case trailing
}
