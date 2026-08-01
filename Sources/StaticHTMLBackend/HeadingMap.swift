import SwiftCrossUI

/// Maps declared text styles onto HTML elements.
///
/// Heading structure comes from the author's declared ``SwiftCrossUI/Font``,
/// which is the only place in the view tree that states intent. Font size,
/// weight, and position are all deliberately ignored: a large bold line is not
/// necessarily a heading, and treating it as one would put guesses into the
/// document outline.
public struct HeadingMap: Sendable {
    /// The element to emit for each mapped font.
    private var elements: [Font: HTMLElement]

    /// The default mapping, following the text styles' documented hierarchy.
    ///
    /// ``SwiftCrossUI/Font/largeTitle`` becomes the page's `h1`, and the three
    /// title styles descend from there. Styles below `title3` aren't mapped:
    /// `headline` and `subheadline` are used for emphasis at least as often as
    /// for sectioning, so promoting them would be a guess.
    public static let `default` = HeadingMap([
        .largeTitle: .h1,
        .title: .h2,
        .title2: .h3,
        .title3: .h4,
    ])

    /// A mapping that derives no headings at all.
    ///
    /// Use this when a page's structure is stated entirely through
    /// ``View/htmlTag(_:)``.
    public static let none = HeadingMap([:])

    /// Creates a mapping.
    ///
    /// - Parameter elements: The element to emit for each declared font.
    public init(_ elements: [Font: HTMLElement]) {
        self.elements = elements
    }

    /// Returns the element that a declared font implies, if any.
    ///
    /// - Parameter font: The un-resolved font declared in the environment.
    /// - Returns: The implied element, or `nil` if the font implies no
    ///   particular semantics.
    public func element(for font: Font?) -> HTMLElement? {
        guard let font else {
            return nil
        }
        return elements[font]
    }
}
