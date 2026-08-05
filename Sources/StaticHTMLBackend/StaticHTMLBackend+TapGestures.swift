@_spi(Backends) import SwiftCrossUI
import SwiftCrossUIComponents

extension StaticHTMLBackend: BackendFeatures.TapGestures {
    /// Marks a view as a tap target without making it tappable.
    ///
    /// Nothing about a tap action is resolvable in pure HTML/CSS, so the
    /// tier-activation principle puts this at the floor as content that
    /// renders normally and carries `data-scui-enliven` for the tier that
    /// can bind it. No wrapper element is introduced: the child is returned
    /// as it is, the way backends that attach gestures to an existing view do
    /// (see ``AndroidBackend``, ``GtkBackend``), so a tap target costs the
    /// emitted document nothing but the marker.
    ///
    /// - Parameters:
    ///   - child: The child to make tappable.
    ///   - gesture: The gesture to listen for.
    /// - Returns: The child, unchanged.
    public func createTapGestureTarget(wrapping child: Widget, gesture: TapGesture) -> Widget {
        child
    }

    /// Records that a tap gesture is waiting on a runtime tier.
    ///
    /// The action is deliberately dropped rather than retained: there is no
    /// script in this tier's output to invoke it, and a widget holding a
    /// closure nothing can ever call would only suggest otherwise. What
    /// survives into the document is ``Widget/awaitsTapEnlivening``, which the
    /// emitter turns into the marker.
    ///
    /// A gesture the author disabled records nothing. `.disabled(true)` is a
    /// hard author override at every tier (matching how every other control
    /// here treats it), so there is no gesture for a later tier to attach.
    ///
    /// - Parameters:
    ///   - tapGestureTarget: The tap gesture target to update.
    ///   - gesture: The gesture to listen for.
    ///   - environment: The current environment.
    ///   - action: The action to perform when a tap gesture occurs.
    public func updateTapGestureTarget(
        _ tapGestureTarget: Widget,
        gesture: TapGesture,
        environment: EnvironmentValues,
        action: @escaping () -> Void
    ) {
        tapGestureTarget.awaitsTapEnlivening = environment.isEnabled
        tapGestureTarget.captureIntent(from: environment)
    }
}
