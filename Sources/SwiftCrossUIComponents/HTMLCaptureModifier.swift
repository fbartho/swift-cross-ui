import SwiftCrossUI

/// A wrapper that records an escape-hatch value onto its own widget.
///
/// The value never enters the environment: this view's node owns a wrapper
/// widget and receives that widget alongside the environment in
/// ``commit(_:children:layout:environment:backend:)``, which is where the
/// capture happens. One application is one node is one widget, so nothing has
/// to recover which application a value came from — a `ForEach` body applying
/// the same modifier to every row produces one wrapper per row by
/// construction.
///
/// The wrapper is the one the modifier would have created anyway, and it stays
/// elidable: capturing a value onto it is what an emitting backend consults to
/// decide whether it survives, not a reason on its own for it to exist.
///
/// Under a backend that doesn't conform to ``HTMLElementCapturing`` the capture
/// is skipped and this is an ordinary pass-through wrapper, which is what makes
/// a tree carrying `.htmlTag(_:)` or `.htmlAttributes(_:)` portable.
struct HTMLCaptureModifier<Child: View>: View {
    var body: TupleView1<Child>
    /// Records the value onto the widget this view owns, under a backend that
    /// can receive it.
    var capture: @MainActor (any HTMLElementCapturing, Any) -> Void

    /// Creates a capturing wrapper.
    ///
    /// - Parameters:
    ///   - child: The view the author modified.
    ///   - capture: Records the value onto the backend's widget.
    init(
        _ child: Child,
        capture: @escaping @MainActor (any HTMLElementCapturing, Any) -> Void
    ) {
        body = TupleView1(child)
        self.capture = capture
    }

    func commit<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: any ViewGraphNodeChildren,
        layout: ViewLayoutResult,
        environment: EnvironmentValues,
        backend: Backend
    ) {
        body.commit(
            widget,
            children: children,
            layout: layout,
            environment: environment,
            backend: backend
        )
        if let backend = backend as? any HTMLElementCapturing {
            capture(backend, widget)
        }
    }
}
