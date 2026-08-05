import SwiftCrossUI

/// One `GeometrySelector` branch, erased to a uniform shape.
///
/// `GeometryCase<Content>` is generic per branch (each can hold different
/// content), so `GeometrySelectorBuilder` erases every branch to this common
/// type to collect them into one array — the same move `ForEach` requires of
/// its own children, and the only way to give `GeometrySelector` a runtime
/// number of heterogeneous branches (`@ViewBuilder`'s `buildBlock` overloads
/// only go up to a fixed arity, and there's no `buildArray`).
///
/// Public because it's the result type `@GeometrySelectorBuilder` closures
/// produce and `GeometrySelector`'s initializers accept — a caller never
/// constructs one by hand.
public struct GSelBranch: Identifiable, Sendable {
    /// A stable identity for `ForEach` diffing — branch declaration order.
    public var id: Int
    /// `nil` for the fallback branch, whose condition is "none of the
    /// others matched" rather than a declared range.
    public var range: WidthRange?
    public var content: AnyView
}

/// Builds a `GeometrySelector`'s branch list from a sequence of `GeometryCase`
/// and (at most one, trailing) `GeometryDefault` values.
///
/// Declarative conditions only, per the ratified design: this builder
/// collects *data* (ranges + content), not closures, so the static tier can
/// compile every branch's gating without evaluating arbitrary logic.
@resultBuilder
@MainActor
public struct GeometrySelectorBuilder {
    public static func buildBlock() -> [GSelBranch] {
        []
    }

    public static func buildPartialBlock<Content: View>(
        first: GeometryCase<Content>
    ) -> [GSelBranch] {
        [GSelBranch(id: 0, range: first.range, content: AnyView(first.content))]
    }

    public static func buildPartialBlock<Content: View>(
        first: GeometryDefault<Content>
    ) -> [GSelBranch] {
        [GSelBranch(id: 0, range: nil, content: AnyView(first.content))]
    }

    public static func buildPartialBlock<Content: View>(
        accumulated: [GSelBranch],
        next: GeometryCase<Content>
    ) -> [GSelBranch] {
        accumulated + [
            GSelBranch(id: accumulated.count, range: next.range, content: AnyView(next.content))
        ]
    }

    public static func buildPartialBlock<Content: View>(
        accumulated: [GSelBranch],
        next: GeometryDefault<Content>
    ) -> [GSelBranch] {
        accumulated + [
            GSelBranch(id: accumulated.count, range: nil, content: AnyView(next.content))
        ]
    }
}
