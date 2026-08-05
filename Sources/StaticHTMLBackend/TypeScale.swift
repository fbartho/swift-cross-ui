@_spi(Backends) import SwiftCrossUI
import SwiftCrossUIComponents

/// Collects the page's text styles and emits them as CSS custom properties.
///
/// This is the color palette's mechanism (see ``ColorPalette``) applied to
/// type. A text style that reaches the document contributes three custom
/// properties — `--scui-fs-<style>`, `--scui-lh-<style>`, and
/// `--scui-fw-<style>` — defined on `:root`, and the interned class that
/// styles the element references them with `var(…)` instead of baking in a
/// pixel value. A `@media` block then swaps the property values at a width
/// breakpoint, so the page's type responds to viewport width with no
/// per-element CSS and no script.
///
/// ## Which tables the query selects between
///
/// The base table is Apple's iOS "Large (Default)" Dynamic Type ramp, in
/// force at every width. Apple's own precedent supports it on the web: Apple
/// Newsroom ships the iOS 17pt body to browsers rather than the 13pt macOS
/// one, and 17px is this framework's body anchor at every viewport size — the
/// compact override never touches it.
///
/// The compact override steps down only the four display sizes
/// (``SwiftCrossUI/Font/TextStyle/largeTitle``,
/// ``SwiftCrossUI/Font/TextStyle/title``,
/// ``SwiftCrossUI/Font/TextStyle/title2``, and
/// ``SwiftCrossUI/Font/TextStyle/title3``), because those are the sizes that
/// misbehave on a narrow viewport: a 34px large title on a 375px-wide phone
/// eats the screen, while body text at that width is already correct. Reading
/// sizes therefore have exactly one value across the whole responsive range.
///
/// The macOS table is deliberately *not* the compact end of this pair. Its
/// 13pt body was evaluated for the web and rejected — using it below the
/// breakpoint would reintroduce the very size the iOS anchor replaced.
public struct TypeScale {
    /// A text style's web-facing metrics.
    struct Metrics: Hashable, Sendable {
        /// The font size, in pixels.
        var fontSize: Double
        /// The line height, in pixels.
        var lineHeight: Double
        /// The CSS font weight.
        var weight: Int
    }

    /// The text styles the page actually used, in the order first seen.
    private var orderedStyles: [Font.TextStyle] = []
    /// Fast membership test for ``orderedStyles``.
    private var seenStyles: Set<Font.TextStyle> = []

    /// The viewport width at or below which the compact overrides apply.
    ///
    /// Sits below the 720px reading measure so the swap only happens once the
    /// measure has stopped being the constraint on line length.
    public static let compactBreakpoint = 600

    /// Creates an empty type scale.
    public init() {}

    /// Records that a text style reached the document, and returns the CSS
    /// values to use for it.
    ///
    /// - Parameter style: The text style the author declared.
    /// - Returns: `var(…)` references for font size, line height, and weight.
    public mutating func values(
        for style: Font.TextStyle
    ) -> (fontSize: String, lineHeight: String, weight: String) {
        if !seenStyles.contains(style) {
            seenStyles.insert(style)
            orderedStyles.append(style)
        }
        let name = Self.name(for: style)
        return (
            fontSize: "var(--scui-fs-\(name))",
            lineHeight: "var(--scui-lh-\(name))",
            weight: "var(--scui-fw-\(name))"
        )
    }

    /// Whether any text style reached the document.
    public var isEmpty: Bool {
        orderedStyles.isEmpty
    }

    /// The `:root` rules defining the type scale's custom properties.
    ///
    /// Returns an empty string when the page used no dynamic text styles, so
    /// pages that don't need the machinery don't carry it. Only the styles
    /// actually used are emitted, and the `@media` block is omitted entirely
    /// when none of them has a compact override.
    public var stylesheet: String {
        guard !orderedStyles.isEmpty else {
            return ""
        }

        func declarations(
            _ table: [Font.TextStyle: Metrics],
            indent: String
        ) -> [String] {
            orderedStyles.compactMap { style in
                guard let metrics = table[style] else {
                    return nil
                }
                let name = Self.name(for: style)
                return """
                    \(indent)--scui-fs-\(name): \(Self.px(metrics.fontSize));
                    \(indent)--scui-lh-\(name): \(Self.px(metrics.lineHeight));
                    \(indent)--scui-fw-\(name): \(metrics.weight);
                    """
            }
        }

        let base = declarations(Self.baseTable, indent: "  ")
            .joined(separator: "\n")
        let compact = declarations(Self.compactOverrides, indent: "    ")
            .joined(separator: "\n")

        var stylesheet = """
            :root {
            \(base)
            }
            """

        if !compact.isEmpty {
            stylesheet += """


                @media (max-width: \(Self.compactBreakpoint)px) {
                  :root {
                \(compact)
                  }
                }
                """
        }

        return stylesheet
    }

    /// The property-name stem for a text style.
    ///
    /// - Parameter style: The text style.
    /// - Returns: A kebab-case stem, so `title2` reads as `title-2`.
    static func name(for style: Font.TextStyle) -> String {
        switch style {
            case .largeTitle: "large-title"
            case .title: "title"
            case .title2: "title-2"
            case .title3: "title-3"
            case .headline: "headline"
            case .subheadline: "subheadline"
            case .body: "body"
            case .callout: "callout"
            case .caption: "caption"
            case .caption2: "caption-2"
            case .footnote: "footnote"
        }
    }

    /// Renders a metric as a CSS pixel length, dropping a trailing `.0`.
    ///
    /// - Parameter value: The length in pixels.
    /// - Returns: The length as a CSS value.
    static func px(_ value: Double) -> String {
        value == value.rounded()
            ? "\(Int(value))px"
            : "\(value)px"
    }

    /// The base table: Apple's iOS "Large (Default)" Dynamic Type ramp.
    ///
    /// Taken value-for-value from the backend's own
    /// ``SwiftCrossUI/Font/TextStyle`` mobile table, which was verified against
    /// Apple's published typography specification. Weights come from the same
    /// source, which is what preserves the Headline/Body distinction: both are
    /// 17px, and only the weight differs (600 against 400) — Apple's own way of
    /// separating the two without a size step.
    static let baseTable: [Font.TextStyle: Metrics] = [
        .largeTitle: Metrics(fontSize: 34, lineHeight: 41, weight: 400),
        .title: Metrics(fontSize: 28, lineHeight: 34, weight: 400),
        .title2: Metrics(fontSize: 22, lineHeight: 28, weight: 400),
        .title3: Metrics(fontSize: 20, lineHeight: 25, weight: 400),
        .headline: Metrics(fontSize: 17, lineHeight: 22, weight: 600),
        .body: Metrics(fontSize: 17, lineHeight: 22, weight: 400),
        .callout: Metrics(fontSize: 16, lineHeight: 21, weight: 400),
        .subheadline: Metrics(fontSize: 15, lineHeight: 20, weight: 400),
        .footnote: Metrics(fontSize: 13, lineHeight: 18, weight: 400),
        .caption: Metrics(fontSize: 12, lineHeight: 16, weight: 400),
        .caption2: Metrics(fontSize: 11, lineHeight: 13, weight: 400),
    ]

    // These four values are INFERRED, not Apple-specified: Apple publishes no
    // narrow-web column, so they're derived by compressing the display end of
    // the base ramp toward body using the proportions Apple's own
    // accessibility size tables step by. They're flagged here the same way the
    // tv and watch tables in Font.TextStyle flag their inferred entries.
    //
    // TODO(fbartho): these are provisional pending in-situ review of the
    //   design-system page at a narrow viewport, which is where the final
    //   numbers get chosen. Editing a row here is the whole change.
    //
    // Only the display sizes appear. Body and the reading styles below it are
    // deliberately absent: 17px body is the anchor at every width, and a style
    // with no entry here simply keeps its base value.
    static let compactOverrides: [Font.TextStyle: Metrics] = [
        .largeTitle: Metrics(fontSize: 28, lineHeight: 34, weight: 400),
        .title: Metrics(fontSize: 24, lineHeight: 30, weight: 400),
        .title2: Metrics(fontSize: 20, lineHeight: 25, weight: 400),
        .title3: Metrics(fontSize: 18, lineHeight: 23, weight: 400),
    ]
}
