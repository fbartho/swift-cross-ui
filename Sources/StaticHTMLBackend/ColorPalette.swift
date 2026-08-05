@_spi(Backends) import SwiftCrossUI
import SwiftCrossUIComponents

/// A color as observed under both color schemes.
///
/// The emitter renders the view tree twice — once with
/// ``SwiftCrossUI/ColorScheme/light`` and once with
/// ``SwiftCrossUI/ColorScheme/dark`` — so every color reaches the palette with
/// both of its resolutions already known.
public struct SchemePair: Hashable, Sendable {
    /// The color as resolved under the light color scheme.
    public var light: Color.Resolved
    /// The color as resolved under the dark color scheme.
    public var dark: Color.Resolved

    /// Whether the color resolves identically under both schemes.
    ///
    /// Scheme-invariant colors don't need a custom property; they can be
    /// written as a literal.
    public var isSchemeInvariant: Bool {
        light == dark
    }

    /// Creates a scheme pair.
    ///
    /// - Parameters:
    ///   - light: The color under the light color scheme.
    ///   - dark: The color under the dark color scheme.
    public init(light: Color.Resolved, dark: Color.Resolved) {
        self.light = light
        self.dark = dark
    }
}

/// Collects the page's colors and emits them as CSS custom properties.
///
/// Colors that differ between schemes become custom properties defined on
/// `:root` with a `prefers-color-scheme: dark` override, so a page picks up
/// the reader's system appearance without any script.
public struct ColorPalette {
    /// The scheme-varying colors, in the order they were first seen.
    private var orderedColors: [SchemePair] = []
    /// The custom property name assigned to each scheme-varying color.
    private var propertyNames: [SchemePair: String] = [:]

    /// Creates an empty palette.
    public init() {}

    /// Returns the CSS value to use for a color.
    ///
    /// Scheme-invariant colors resolve to an `rgba(…)` literal. Colors that
    /// differ between schemes get a custom property, and the returned value is
    /// a `var(…)` reference to it.
    ///
    /// - Parameter pair: The color as resolved under both schemes.
    /// - Returns: A CSS value usable on the right-hand side of a declaration.
    public mutating func value(for pair: SchemePair) -> String {
        guard !pair.isSchemeInvariant else {
            return Self.cssLiteral(pair.light)
        }
        let name: String
        if let existing = propertyNames[pair] {
            name = existing
        } else {
            name = "--scui-c\(String(orderedColors.count, radix: 36))"
            orderedColors.append(pair)
            propertyNames[pair] = name
        }
        return "var(\(name))"
    }

    /// The `:root` rules defining the palette's custom properties.
    ///
    /// Returns an empty string when every color on the page was
    /// scheme-invariant, so pages that don't need the machinery don't carry
    /// it.
    public var stylesheet: String {
        guard !orderedColors.isEmpty else {
            return ""
        }

        func block(_ scheme: KeyPath<SchemePair, Color.Resolved>) -> String {
            orderedColors
                .enumerated()
                .map { index, pair in
                    let name = "--scui-c\(String(index, radix: 36))"
                    return "  \(name): \(Self.cssLiteral(pair[keyPath: scheme]));"
                }
                .joined(separator: "\n")
        }

        return """
            :root {
            \(block(\.light))
            }

            @media (prefers-color-scheme: dark) {
              :root {
            \(block(\.dark))
              }
            }
            """
    }

    /// Renders a resolved color as a CSS `rgba(…)` literal.
    ///
    /// - Parameter color: The color to render.
    /// - Returns: The color as a CSS value.
    static func cssLiteral(_ color: Color.Resolved) -> String {
        let red = Int((color.red * 255).rounded())
        let green = Int((color.green * 255).rounded())
        let blue = Int((color.blue * 255).rounded())
        // Trim the opacity to three decimal places so that colors that differ
        // only by floating point noise still produce identical CSS.
        let opacity = (Double(color.opacity) * 1000).rounded() / 1000
        return "rgba(\(red),\(green),\(blue),\(opacity))"
    }
}
