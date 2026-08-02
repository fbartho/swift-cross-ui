import Foundation
import SwiftCrossUI

/// A half-open range of widths, in CSS pixels.
///
/// `GeometrySelector`'s branches are declared against ranges rather than a
/// single breakpoint, which is what makes N-ary branches and gap/overlap
/// validation possible. A bound of `nil` means unbounded in that direction.
///
/// Construct one from a standard range expression:
///
/// ```swift
/// WidthCase(..<600) { … }    // WidthRange(upperBound: 600)
/// WidthCase(600...) { … }    // WidthRange(lowerBound: 600)
/// WidthCase(600..<900) { … } // WidthRange(lowerBound: 600, upperBound: 900)
/// ```
public struct WidthRange: Hashable, Sendable, CustomStringConvertible {
    /// The range's lower bound, inclusive. `nil` means unbounded below.
    public var lowerBound: Double?
    /// The range's upper bound, exclusive. `nil` means unbounded above.
    public var upperBound: Double?

    /// Creates a range from explicit optional bounds.
    ///
    /// - Parameters:
    ///   - lowerBound: The inclusive lower bound, or `nil` for unbounded.
    ///   - upperBound: The exclusive upper bound, or `nil` for unbounded.
    public init(lowerBound: Double? = nil, upperBound: Double? = nil) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    /// Creates a range from a bounded `Range`.
    public init(_ range: Range<Double>) {
        self.init(lowerBound: range.lowerBound, upperBound: range.upperBound)
    }

    /// Creates a range from an upper-bounded-only range (`..<900`).
    public init(_ range: PartialRangeUpTo<Double>) {
        self.init(upperBound: range.upperBound)
    }

    /// Creates a range from a lower-bounded-only range (`600...`).
    public init(_ range: PartialRangeFrom<Double>) {
        self.init(lowerBound: range.lowerBound)
    }

    public var description: String {
        "\(lowerBound.map { "\($0)" } ?? "-∞")..<\(upperBound.map { "\($0)" } ?? "+∞")"
    }

    /// Whether this range and another overlap.
    ///
    /// Two unbounded-in-the-same-direction ranges (e.g. both `600...`) are
    /// considered overlapping, since every width past 600 matches both.
    func overlaps(_ other: WidthRange) -> Bool {
        let selfStart = lowerBound ?? -.infinity
        let selfEnd = upperBound ?? .infinity
        let otherStart = other.lowerBound ?? -.infinity
        let otherEnd = other.upperBound ?? .infinity
        return selfStart < otherEnd && otherStart < selfEnd
    }

    /// The CSS media/container feature declarations this range compiles to,
    /// e.g. `(min-width: 600px)` or `(min-width: 600px) and (max-width: 899.98px)`.
    ///
    /// The upper bound is exclusive (a `WidthCase(..<900)` branch must not
    /// apply at exactly 900px, where the next branch begins), but CSS range
    /// media features have no exclusive-max syntax, so the bound is nudged
    /// down by a hairline (0.02px, below any real viewport's precision) to
    /// approximate "strictly less than" with `max-width`.
    var cssFeatures: String {
        var parts: [String] = []
        if let lowerBound {
            parts.append("(min-width: \(Self.formatCSSLength(lowerBound)))")
        }
        if let upperBound {
            parts.append("(max-width: \(Self.formatCSSLength(upperBound - 0.02)))")
        }
        return parts.joined(separator: " and ")
    }

    /// The negation of `cssFeatures`, for hiding a branch outside its own
    /// range.
    ///
    /// A single-feature range (`600...` or `..<900`) negates as
    /// `not (min-width: 600px)` — no extra parens needed, since `not` only
    /// has one feature to bind to. A bounded range (`600..<900`) is TWO
    /// features joined by `and`, and `not` binds to only the FIRST feature
    /// unless the whole conjunction is explicitly parenthesized — browser-
    /// verified (headless Chrome): `not (min-width: 600px) and (max-width:
    /// 899.98px)` never matches at ANY width (De Morgan's `not(A and B)` ≠
    /// `not(A) and B`, and the unparenthesized form silently parses as the
    /// latter). The correct form groups the whole feature list:
    /// `not ((min-width: 600px) and (max-width: 899.98px))`.
    var negatedCSSFeatures: String {
        let features = cssFeatures
        // A single feature (no " and ") needs no extra grouping; `not`
        // binds to it directly and unambiguously.
        return features.contains(" and ") ? "not (\(features))" : "not \(features)"
    }

    /// Whether a measured width falls inside this range.
    ///
    /// - Parameter width: The width to test, in the same units as the range's
    ///   bounds.
    /// - Returns: Whether `width` is within `[lowerBound, upperBound)`.
    func contains(_ width: Double) -> Bool {
        if let lowerBound, width < lowerBound {
            return false
        }
        if let upperBound, width >= upperBound {
            return false
        }
        return true
    }

    /// Formats a length for CSS, dropping a trailing `.0` where possible.
    private static func formatCSSLength(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return "\(Int(value))px"
        }
        return "\(value)px"
    }
}

extension GeometrySelector {
    /// A condition under which one of a `GeometrySelector`'s branches is
    /// active.
    ///
    /// Every case documents both halves of its meaning, per the both-halves
    /// rule: how it compiles to CSS for the static tier, and how it's
    /// answered on a measuring tier (native, wasm) via `GeometryReader`-style
    /// measurement. A case that can't state both isn't ready to ship.
    ///
    /// v1 ships two cases. The shape (an enum, not a struct) is deliberate:
    /// it leaves room for later composition (conjunction/disjunction/negation,
    /// per the ratified design) and later kinds (print, reduced motion, …)
    /// without an API break to existing callers.
    ///
    /// Task #26 shipped the MEASURING-tier half of three of those future
    /// kinds early, as plain environment values rather than `Condition`
    /// cases: ``EnvironmentValues/reducedMotion``,
    /// ``EnvironmentValues/pointerCapability``, and
    /// ``EnvironmentValues/printActive``. Each documents its own CSS half
    /// (`@media (prefers-reduced-motion: …)`, `@media (pointer: …)`,
    /// `@media print`) and its static-tier default. When `.reducedMotion` /
    /// `.pointerCapability` / `.print` cases land here, their measuring-tier
    /// arms read those same environment values rather than duplicating the
    /// "what can the static tier honestly know" reasoning a second time.
    public enum Condition: Hashable, Sendable {
        /// Active when the viewport's width falls in `range`.
        ///
        /// **CSS compilation:** `@media <range.cssFeatures> { … }`.
        /// **Measuring tier:** answered from the nearest enclosing
        /// `GeometryReader`'s proposed width — see
        /// `GeometrySelector`'s measuring-tier arm.
        case viewportWidth(WidthRange)

        /// Active when the named container's width falls in `range`.
        ///
        /// The container must have been marked with `.container(name)` on an
        /// ancestor; an unnamed/unmarked container query is a construction-time
        /// error (required names, per the ratified container-query design).
        ///
        /// **CSS compilation:** `@container <name> <range.cssFeatures> { … }`,
        /// which resolves against the nearest ancestor carrying
        /// `container-name: <name>` (`inline-size` containment — width only).
        /// **Measuring tier:** unsupported in v1 — `GeometryProxy` exposes only
        /// the size proposed by the immediate parent, with no notion of a
        /// named ancestor container (see `GeometryProxy.size`), so a
        /// `.containerWidth` condition can't be evaluated outside the static
        /// tier yet. `GeometrySelector`'s measuring-tier arm falls back to the
        /// first branch whose condition is a `.containerWidth` it cannot
        /// evaluate, treating it as always-inactive during measurement — an
        /// honest gap, not a silent wrong answer, documented on
        /// `GeometrySelector` itself.
        case containerWidth(name: String, range: WidthRange)

        /// The width range this condition is scoped to, if it's width-based.
        ///
        /// Every v1 case is width-based, so this is never `nil` today; it
        /// stays `Optional` because a later condition kind (print,
        /// reduced-motion) has no width range at all.
        var widthRange: WidthRange? {
            switch self {
                case .viewportWidth(let range):
                    range
                case .containerWidth(_, let range):
                    range
            }
        }

        /// The container name this condition is scoped to, if it's a
        /// container query.
        var containerName: String? {
            switch self {
                case .viewportWidth:
                    nil
                case .containerWidth(let name, _):
                    name
            }
        }

        /// The CSS at-rule preamble this condition compiles to, e.g.
        /// `@media (min-width: 600px)` or `@container sidebar (min-width: 400px)`.
        var cssAtRule: String {
            switch self {
                case .viewportWidth(let range):
                    "@media \(range.cssFeatures)"
                case .containerWidth(let name, let range):
                    "@container \(GSelCSS.identifier(name)) \(range.cssFeatures)"
            }
        }

        /// The at-rule for the NEGATION of this condition — see
        /// `WidthRange.negatedCSSFeatures` for the parenthesization this
        /// depends on. Used to hide a ranged branch outside its own range,
        /// including inside a gap no other branch's own range covers (the
        /// case a fallback exists for): the branch's negated condition fires
        /// there even though no sibling's own at-rule does.
        var negatedCSSAtRule: String {
            switch self {
                case .viewportWidth(let range):
                    "@media \(range.negatedCSSFeatures)"
                case .containerWidth(let name, let range):
                    "@container \(GSelCSS.identifier(name)) \(range.negatedCSSFeatures)"
            }
        }

        /// A stable sort key so registered at-rules emit in deterministic
        /// order: viewport conditions before container conditions, then by
        /// container name, then by ascending lower bound — matching the
        /// breakpoint design's documented ordering rule.
        var sortKey: (kind: Int, containerName: String, lowerBound: Double) {
            switch self {
                case .viewportWidth(let range):
                    (0, "", range.lowerBound ?? -.infinity)
                case .containerWidth(let name, let range):
                    (1, name, range.lowerBound ?? -.infinity)
            }
        }

        /// Whether a measured width satisfies this condition.
        ///
        /// Returns `false` for `.containerWidth`, per that case's documented
        /// measuring-tier gap.
        ///
        /// - Parameter width: The measured width to test.
        func matches(measuredWidth width: Double) -> Bool {
            switch self {
                case .viewportWidth(let range):
                    range.contains(width)
                case .containerWidth:
                    false
            }
        }
    }
}

/// Small CSS-text helpers shared by `GeometrySelector` and `.container(_:)`.
///
/// Not a general-purpose CSS escaper — scoped narrowly to the two things
/// GeometrySelector's emission needs: a safe `<custom-ident>` for
/// `container-name`/`@container`, and a safe attribute-selector string
/// literal for `[data-gsel-container="…"]`.
enum GSelCSS {
    /// A CSS-identifier-safe rendering of a name, for `container-name` and
    /// `@container <name>`.
    ///
    /// Container names follow the `<custom-ident>` grammar; this doesn't
    /// attempt full validation, only strips characters that would break the
    /// generated stylesheet if an author supplied something unusual.
    static func identifier(_ name: String) -> String {
        let sanitized = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return sanitized.isEmpty ? "gsel" : sanitized
    }

    /// Escapes a string for use inside a double-quoted CSS attribute-selector
    /// value, e.g. `[data-gsel-container="<escaped>"]`.
    static func attributeSelectorLiteral(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        for character in value {
            switch character {
                case "\\": output += "\\\\"
                case "\"": output += "\\\""
                default: output.append(character)
            }
        }
        return output
    }
}
