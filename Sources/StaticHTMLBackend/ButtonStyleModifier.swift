import SwiftCrossUI

/// A button's high-level appearance, in SwiftUI's vocabulary.
///
/// The static tier gives buttons an appearance of its own because the reset
/// flattens the user-agent one and a native backend's button takes its look
/// from the platform widget rather than from anything declared in Swift. This
/// selects among those appearances.
///
/// Applied with ``SwiftCrossUI/View/htmlButtonStyle(_:)``, which — like
/// ``SwiftCrossUI/View/htmlTag(_:)`` and ``SwiftCrossUI/View/href(_:)`` — only
/// affects StaticHTMLBackend, so a view hierarchy carrying it stays portable.
///
/// Core has no `ButtonStyle` concept, so there is nothing here to bridge to.
/// Should one arrive, this becomes its static-tier translation rather than a
/// competing spelling.
public enum HTMLButtonStyle: String, Hashable, Sendable, CaseIterable {
    /// The backend's default: a bordered button.
    ///
    /// Named for SwiftUI's `.automatic`, which likewise means "whatever this
    /// platform considers a button" rather than a specific appearance.
    case automatic

    /// An explicitly bordered button. Identical in appearance to
    /// ``automatic`` at this tier, and spelled separately because an author
    /// asking for a border is making a stronger claim than one accepting the
    /// default — a future tier is free to move ``automatic`` and leave this
    /// one where it is.
    case bordered

    /// A filled, high-emphasis button for the primary action in a view.
    case borderedProminent

    /// A button drawn as tinted text, with no border or fill until hovered.
    case borderless

    /// A button with no decoration at all, taking the surrounding text's
    /// appearance. The escape hatch for a control whose framing comes from
    /// somewhere else in the design.
    case plain

    /// The class this style is emitted as.
    ///
    /// Public because it's part of the emitted contract: a page owner
    /// overriding the reset, or writing rules of their own against the
    /// output, needs the name the markup actually carries.
    public var className: String {
        "scui-btn-\(rawValue.lowercased())"
    }
}

extension EnvironmentValues {
    /// The button appearance requested by
    /// ``SwiftCrossUI/View/htmlButtonStyle(_:)``.
    ///
    /// Unlike the tag/href/attribute requests, this is a plain inherited value
    /// rather than an identity-resolved request object: those name one
    /// element each and so must find the single widget the author applied
    /// them to, whereas a button style covers every button beneath it, the
    /// same way ``SwiftCrossUI/EnvironmentValues/font`` covers every text.
    ///
    /// Only consumed by StaticHTMLBackend; other backends never read it.
    @Entry public var htmlButtonStyle: HTMLButtonStyle = .automatic
}

extension View {
    /// Sets the appearance of buttons in this view.
    ///
    /// The style applies to every button in the subtree, not just a directly
    /// modified one, so a toolbar's worth of buttons can be styled at once.
    /// A nested call overrides an enclosing one for its own subtree.
    ///
    /// This modifier only affects StaticHTMLBackend. Under any other backend
    /// it does nothing, so a view hierarchy carrying it stays portable.
    ///
    /// - Parameter style: The appearance to give buttons in this view.
    /// - Returns: The view, with its buttons restyled.
    public func htmlButtonStyle(_ style: HTMLButtonStyle) -> some View {
        environment(\.htmlButtonStyle, style)
    }
}
