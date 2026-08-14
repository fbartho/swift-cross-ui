import SwiftCrossUI

/// A wrapper that records an escape-hatch value onto its own widget.
///
/// The value never enters the environment: this view's node owns a wrapper
/// widget and receives that widget alongside the environment in
/// ``commit(_:children:layout:environment:backend:)``, which is where the
/// anchoring happens. One application is one node is one widget, so the
/// application a value came from is settled structurally — a `ForEach` body
/// applying the same modifier to every row produces one wrapper per row by
/// construction.
///
/// The wrapper stays elidable: an anchored value is something an emitting
/// backend consults when deciding whether the wrapper survives, not a reason
/// on its own for it to exist.
///
/// Under a backend that doesn't conform to ``HTMLElementAnchoring`` the
/// anchoring is skipped and this is an ordinary pass-through wrapper, which is
/// what makes a tree carrying `.htmlTag(_:)` or `.htmlAttributes(_:)`
/// portable.
struct HTMLAnchoringModifier<Child: View>: View {
    var body: TupleView1<Child>
    /// Records the value onto the widget this view owns, under a backend that
    /// can receive it.
    var anchor: @MainActor (any HTMLElementAnchoring, Any) -> Void

    /// Creates an anchoring wrapper.
    ///
    /// - Parameters:
    ///   - child: The view the author modified.
    ///   - anchor: Records the value onto the backend's widget.
    init(
        _ child: Child,
        anchor: @escaping @MainActor (any HTMLElementAnchoring, Any) -> Void
    ) {
        body = TupleView1(child)
        self.anchor = anchor
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
        if let backend = backend as? any HTMLElementAnchoring {
            anchor(backend, widget)
        }
    }
}
