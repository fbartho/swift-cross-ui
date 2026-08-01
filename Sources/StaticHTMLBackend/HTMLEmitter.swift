import Foundation
@_spi(Backends) import SwiftCrossUI

/// Serializes a committed widget tree into HTML.
///
/// Element choice runs through three layers, in order:
///
/// 1. An explicit ``View/htmlTag(_:)`` on the view, which always wins.
/// 2. A heading derived from the author's declared text style, via
///    ``HeadingMap``.
/// 3. A `div` (or `span` for text) carrying an ARIA role where the widget's
///    type implies one.
///
/// Nothing outside those three layers gets to influence semantics. Geometry
/// and styling never do.
@MainActor
public struct HTMLEmitter {
    /// The mapping from declared text styles to heading elements.
    public var headingMap: HeadingMap
    /// The interner that collapses duplicate styles into shared classes.
    public var interner = StyleInterner()
    /// The palette that turns scheme-varying colors into custom properties.
    public var palette = ColorPalette()

    /// Creates an emitter.
    ///
    /// - Parameter headingMap: The mapping to derive headings with.
    public init(headingMap: HeadingMap = .default) {
        self.headingMap = headingMap
    }

    /// Emits a widget and its descendants.
    ///
    /// - Parameters:
    ///   - widget: The widget to emit.
    ///   - origin: The widget's position relative to its parent, which the
    ///     emitted CSS mirrors with `position: absolute`.
    ///   - indentLevel: How far to indent the emitted markup.
    /// - Returns: The widget's markup.
    public mutating func emit(
        _ widget: StaticHTMLBackend.Widget,
        at origin: SIMD2<Int>,
        indentLevel: Int = 0
    ) -> String {
        let indent = String(repeating: "  ", count: indentLevel + 1)

        var style = Style()
        style.set("absolute", for: "position")
        style.set("\(origin.x)px", for: "left")
        style.set("\(origin.y)px", for: "top")
        style.set("\(widget.size.x)px", for: "width")
        style.set("\(widget.size.y)px", for: "height")
        if widget.cornerRadius > 0 {
            style.set("\(widget.cornerRadius)px", for: "border-radius")
        }

        var element = HTMLElement.div
        var role: String?
        var inner = ""
        var isRawInner = false

        switch widget {
            case let text as StaticHTMLBackend.TextView:
                element = .span
                if let font = text.font {
                    style.set("\(Int(font.pointSize))px", for: "font-size")
                    style.set("\(Int(font.lineHeight))px", for: "line-height")
                    style.set(Self.cssWeight(font.weight), for: "font-weight")
                    if font.isItalic {
                        style.set("italic", for: "font-style")
                    }
                    if font.design == .monospaced {
                        style.set("monospace", for: "font-family")
                    }
                }
                if let color = text.color {
                    style.set(palette.value(for: color), for: "color")
                }
                style.set("pre-wrap", for: "white-space")
                // Measurement on the build host is an estimate, so the browser
                // may want one more line than was allocated. Clipping keeps
                // that drift inside the element's own box instead of letting it
                // run over whatever the layout system placed below. This
                // matches what ``Text`` does when it truncates on screen, and
                // is the same failure mode a windowing backend would show.
                style.set("hidden", for: "overflow")
                inner = Self.escape(text.content)
                // A declared text style is the author saying what this line is
                // for, so it outranks the generic span.
                if let derived = headingMap.element(for: text.declaredFont) {
                    element = derived
                }

            case let button as StaticHTMLBackend.Button:
                // With no runtime there's nothing to click, so a button is
                // emitted as a link and given the role it plays.
                element = .custom("a")
                role = "button"
                style.set("flex", for: "display")
                style.set("center", for: "align-items")
                style.set("center", for: "justify-content")
                style.set("none", for: "text-decoration")
                style.set("border-box", for: "box-sizing")
                inner = Self.escape(button.label)

            case let rectangle as StaticHTMLBackend.Rectangle:
                if let color = rectangle.color {
                    style.set(palette.value(for: color), for: "background-color")
                }

            case let container as StaticHTMLBackend.Container:
                inner = emitChildren(
                    container.children,
                    indent: indent,
                    indentLevel: indentLevel
                )
                isRawInner = true

            case let scroll as StaticHTMLBackend.ScrollContainer:
                style.set("auto", for: "overflow")
                inner = emitChildren(
                    [(scroll.child, .zero)],
                    indent: indent,
                    indentLevel: indentLevel
                )
                isRawInner = true

            default:
                let children = widget.getChildren()
                if !children.isEmpty {
                    inner = emitChildren(
                        children.map { ($0, SIMD2<Int>.zero) },
                        indent: indent,
                        indentLevel: indentLevel
                    )
                    isRawInner = true
                }
        }

        // An explicit tag is the author overriding everything above.
        if let explicit = widget.explicitElement, explicit.isValid {
            element = explicit
        }

        var attributes: [String: String] = [:]
        // Author attributes are merged first so that backend-owned ones
        // overwrite them rather than the other way around.
        for (name, value) in widget.authorAttributes
            where HTMLElement.isValidName(name) && !Self.reservedAttributes.contains(name)
        {
            attributes[name] = value
        }
        if let role, attributes["role"] == nil {
            attributes["role"] = role
        }
        if element.name == "a" {
            attributes["href"] = attributes["href"] ?? "#"
        }
        if let tag = widget.tag {
            attributes["data-scui"] = tag
        }
        if let className = interner.className(for: style) {
            attributes["class"] = className
        }

        let renderedAttributes =
            attributes
                .sorted { $0.key < $1.key }
                .map { name, value in " \(name)=\"\(Self.escape(value))\"" }
                .joined()

        guard !element.isVoid else {
            return "\(indent)<\(element.name)\(renderedAttributes)>"
        }

        let body = isRawInner ? "\(inner)\(indent)" : inner
        return "\(indent)<\(element.name)\(renderedAttributes)>\(body)</\(element.name)>"
    }

    /// Emits a widget's children, each on its own line.
    private mutating func emitChildren(
        _ children: [(widget: StaticHTMLBackend.Widget, position: SIMD2<Int>)],
        indent: String,
        indentLevel: Int
    ) -> String {
        guard !children.isEmpty else {
            return ""
        }
        var output = "\n"
        for (childWidget, childPosition) in children {
            output += emit(childWidget, at: childPosition, indentLevel: indentLevel + 1)
            output += "\n"
        }
        return output
    }

    /// Attributes that the backend owns and authors may not overwrite.
    ///
    /// `style` is absent from the emitted markup entirely (styling goes
    /// through interned classes), so letting an author set it would reintroduce
    /// exactly the inline styling this backend avoids.
    nonisolated static let reservedAttributes: Set<String> = ["style", "class", "data-scui"]

    /// Maps a resolved font weight to its CSS numeric equivalent.
    nonisolated static func cssWeight(_ weight: Font.Weight) -> String {
        switch weight {
            case .ultraLight: "100"
            case .thin: "200"
            case .light: "300"
            case .regular: "400"
            case .medium: "500"
            case .semibold: "600"
            case .bold: "700"
            case .heavy: "800"
            case .black: "900"
        }
    }

    /// Escapes a string for inclusion in markup or an attribute value.
    ///
    /// - Parameter string: The string to escape.
    /// - Returns: The escaped string.
    public nonisolated static func escape(_ string: String) -> String {
        var output = ""
        output.reserveCapacity(string.count)
        for character in string {
            switch character {
                case "&": output += "&amp;"
                case "<": output += "&lt;"
                case ">": output += "&gt;"
                case "\"": output += "&quot;"
                case "'": output += "&#39;"
                default: output.append(character)
            }
        }
        return output
    }
}
