/// A divider that expands along the minor axis of the containing stack layout.
///
/// If not contained within a stack, this view expands horizontally.
///
/// In dark mode it's white with 10% opacity, and in light mode it's black with
/// 10% opacity.
public struct Divider: TypeSafeView, Sendable {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.layoutOrientation) var layoutOrientation

    let requestedColor: Color?

    /// Creates a divider. Uses the provided color, or adapts to the current
    /// color scheme if nil.
    public init(_ color: Color? = nil) {
        self.requestedColor = color
    }

    var color: Color {
        requestedColor ?? Color.adaptive(light: .black, dark: .white)
    }

    public var body: some View {
        color
            .opacity(0.1)
            .frame(
                width: layoutOrientation == .horizontal ? 1 : nil,
                height: layoutOrientation == .vertical ? 1 : nil
            )
    }

    func children<Backend: BaseAppBackend>(
        backend: Backend,
        snapshots: [ViewGraphSnapshotter.NodeSnapshot]?,
        environment: EnvironmentValues
    ) -> TupleViewChildren1<Content> {
        TupleView1(body).children(backend: backend, snapshots: snapshots, environment: environment)
    }

    func asWidget<Backend: BaseAppBackend>(
        _ children: TupleViewChildren1<Content>,
        backend: Backend
    ) -> Backend.Widget {
        // No widget of Divider's own: it reuses whatever its composed
        // content (Color → opacity → frame) already produces, exactly as
        // ``AspectRatioView`` does for `.aspectRatio(_:contentMode:)`. The
        // difference from the plain-``View`` `body` this replaces is only
        // in how the widget gets marked — see ``commit`` below — not in
        // what widget exists.
        children.child0.widget.into()
    }

    func computeLayout<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: TupleViewChildren1<Content>,
        proposedSize: ProposedViewSize,
        environment: EnvironmentValues,
        backend: Backend
    ) -> ViewLayoutResult {
        children.child0.computeLayout(
            with: body,
            proposedSize: proposedSize,
            environment: environment
        )
    }

    func commit<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: TupleViewChildren1<Content>,
        layout: ViewLayoutResult,
        environment: EnvironmentValues,
        backend: Backend
    ) {
        _ = children.child0.commit()
        // Divider composes entirely from existing views (``Color``,
        // `.opacity`, `.frame`) rather than owning distinctive geometry of
        // its own, so nothing in its output distinguishes it from any other
        // view with the same committed size — a backend re-expressing the
        // layout in a system with its own flow rules (a CSS flex container,
        // say) needs to be told explicitly which widget is the divider.
        backend.describeDivider(of: widget)
    }

    public var _asMenuItems: [MenuItem] {
        [.separator(self)]
    }
}
