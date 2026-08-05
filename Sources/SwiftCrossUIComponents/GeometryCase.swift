import SwiftCrossUI

/// One branch of a `GeometrySelector`, active over a width range.
///
/// ```swift
/// GeometrySelector {
///     GeometryCase(..<600) { VStack { navLinks } }
///     GeometryCase(600...) { HStack { navLinks } }
/// }
/// ```
///
/// By default a `GeometryCase` is a viewport-width condition. Use
/// `GeometrySelector(of:)` to scope every branch to a named container
/// instead — see that initializer.
public struct GeometryCase<Content: View> {
    /// The range this branch is active over.
    var range: WidthRange
    /// The branch's content.
    var content: Content

    /// Creates a branch active over a bounded range (`600..<900`).
    ///
    /// - Parameters:
    ///   - range: The width range this branch is active over.
    ///   - content: The branch's content.
    public init(_ range: Range<Double>, @ViewBuilder content: () -> Content) {
        self.range = WidthRange(range)
        self.content = content()
    }

    /// Creates a branch active from a lower bound upward (`600...`).
    ///
    /// - Parameters:
    ///   - range: The width range this branch is active over.
    ///   - content: The branch's content.
    public init(_ range: PartialRangeFrom<Double>, @ViewBuilder content: () -> Content) {
        self.range = WidthRange(range)
        self.content = content()
    }

    /// Creates a branch active up to an upper bound (`..<600`).
    ///
    /// - Parameters:
    ///   - range: The width range this branch is active over.
    ///   - content: The branch's content.
    public init(_ range: PartialRangeUpTo<Double>, @ViewBuilder content: () -> Content) {
        self.range = WidthRange(range)
        self.content = content()
    }
}

/// A `GeometrySelector` branch that renders when no `GeometryCase` matches.
///
/// ```swift
/// GeometrySelector {
///     GeometryCase(600..<900) { … }
///     GeometryCase(900...) { … }
///     GeometryDefault { … }
/// }
/// ```
///
/// A gap in the declared ranges is a construction-time error unless a
/// fallback is present — see `GeometrySelector`'s validation. The fallback's
/// CSS is cheap by construction: a hide-rule under every other branch's
/// at-rule, never a computed complement of the declared ranges (per the
/// ratified design).
public struct GeometryDefault<Content: View> {
    /// The fallback's content.
    var content: Content

    /// Creates a fallback branch.
    ///
    /// - Parameter content: The content to render when no other branch
    ///   matches.
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
}
