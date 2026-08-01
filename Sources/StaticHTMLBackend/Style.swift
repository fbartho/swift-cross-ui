/// A resolved set of CSS declarations for a single element.
///
/// Styles are values, not strings, so that identical styling across many
/// widgets collapses to a single generated class. Declarations are stored
/// sorted by property name so that two styles built in different orders still
/// compare and hash equal.
public struct Style: Hashable, Sendable {
    /// The style's declarations, keyed by CSS property name.
    private var declarations: [String: String]

    /// Creates an empty style.
    public init() {
        declarations = [:]
    }

    /// Creates a style from a set of declarations.
    ///
    /// - Parameter declarations: The declarations, keyed by CSS property name.
    public init(_ declarations: [String: String]) {
        self.declarations = declarations
    }

    /// Whether the style has no declarations.
    public var isEmpty: Bool {
        declarations.isEmpty
    }

    /// Sets a declaration, replacing any existing value for the property.
    ///
    /// - Parameters:
    ///   - value: The declaration's value. If `nil`, the property is removed.
    ///   - property: The CSS property name.
    public mutating func set(_ value: String?, for property: String) {
        declarations[property] = value
    }

    /// Returns the value set for a property, if any.
    ///
    /// - Parameter property: The CSS property name.
    /// - Returns: The property's value, or `nil` if the property isn't set.
    public func value(for property: String) -> String? {
        declarations[property]
    }

    /// The style's declarations rendered as a CSS declaration block body.
    ///
    /// Properties appear in sorted order so that output is deterministic.
    public var cssBody: String {
        declarations
            .sorted { $0.key < $1.key }
            .map { property, value in "\(property):\(value)" }
            .joined(separator: ";")
    }
}

/// Assigns generated class names to styles, collapsing duplicates.
///
/// The emitter interns every element's style here rather than writing inline
/// `style` attributes, so a page with a hundred identically-styled rows emits
/// one class and a hundred references to it.
public struct StyleInterner {
    /// The interned styles, in the order they were first seen.
    private var orderedStyles: [Style] = []
    /// The class name assigned to each interned style.
    private var classNames: [Style: String] = [:]

    /// Creates an empty interner.
    public init() {}

    /// Returns the class name for a style, assigning one if the style is new.
    ///
    /// Empty styles get no class, since an element with no declarations has
    /// nothing to reference.
    ///
    /// - Parameter style: The style to intern.
    /// - Returns: The style's generated class name, or `nil` if `style` is
    ///   empty.
    public mutating func className(for style: Style) -> String? {
        guard !style.isEmpty else {
            return nil
        }
        if let existing = classNames[style] {
            return existing
        }
        let name = "scui-\(String(orderedStyles.count, radix: 36))"
        orderedStyles.append(style)
        classNames[style] = name
        return name
    }

    /// The stylesheet defining every interned class.
    ///
    /// Rules appear in the order their styles were first interned.
    public var stylesheet: String {
        orderedStyles
            .enumerated()
            .map { index, style in
                ".scui-\(String(index, radix: 36)) { \(style.cssBody) }"
            }
            .joined(separator: "\n")
    }
}
