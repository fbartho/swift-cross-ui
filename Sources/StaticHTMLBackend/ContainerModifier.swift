import SwiftCrossUI

/// The attribute name `.container(_:)` marks its element with, and
/// `GeometrySelector.Condition.containerWidth` at-rules resolve against.
private let containerMarkerAttribute = "data-gsel-container"

extension View {
    /// Marks this view as a CSS containment context that a descendant
    /// `GeometrySelector` can query by width.
    ///
    /// `@container` queries can't query the element that declares them — an
    /// element can't ask "when am I narrower than 400px, restyle me"; only
    /// an ancestor can be the container being asked about. This modifier
    /// opts an ancestor in, under a name a descendant's
    /// `GeometrySelector(of: .container(name))` refers back to.
    ///
    /// Naming is required, not optional: an unnamed `@container` query
    /// resolves to the nearest container ancestor, whatever wrapper the
    /// emitter happened to produce — fragile against ordinary wrapper-nesting
    /// churn. A required name makes the binding explicit and stable.
    ///
    /// Containment is always `inline-size` (width only), never `size`
    /// (both axes): `size` containment collapses the container's height
    /// unless it's explicitly sized, which would silently break ordinary
    /// flow layout. `inline-size` is safe by default and exactly matches
    /// "query by width," which is all `GeometrySelector` needs.
    ///
    /// This modifier only affects StaticHTMLBackend. Under any other backend
    /// it does nothing, so a view hierarchy carrying it stays portable —
    /// container-width `GeometrySelector` branches simply can't be evaluated
    /// there (documented gap on `GeometrySelector.Condition.containerWidth`).
    ///
    /// - Parameter name: The name a descendant `GeometrySelector` refers to
    ///   this container by. Must be non-empty.
    /// - Returns: The view, marked as a named width-containment context.
    public func container(_ name: String) -> some View {
        precondition(
            !name.isEmpty,
            "container(_:) requires a non-empty name — an unnamed container "
                + "query would resolve against whichever wrapper the emitter "
                + "happened to produce, not the container you meant."
        )
        return htmlAttributes([containerMarkerAttribute: name])
            .htmlHeadItem(
                .style(
                    """
                    [\(containerMarkerAttribute)="\(GSelCSS.attributeSelectorLiteral(name))"] { \
                    container-type: inline-size; \
                    container-name: \(GSelCSS.identifier(name)); \
                    }
                    """
                ),
                id: "gsel-container-\(name)"
            )
    }
}
