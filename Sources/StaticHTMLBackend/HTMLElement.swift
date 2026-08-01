/// An HTML element name that ``View/htmlTag(_:)`` can assign to a view.
///
/// The enum cases cover the elements that come up when giving a static page
/// its document structure. Elements outside this list are still reachable via
/// ``HTMLElement/custom(_:)``, which validates the name it's given.
public enum HTMLElement: Hashable, Sendable {
    /// A first level heading.
    case h1
    /// A second level heading.
    case h2
    /// A third level heading.
    case h3
    /// A fourth level heading.
    case h4
    /// A fifth level heading.
    case h5
    /// A sixth level heading.
    case h6
    /// A paragraph.
    case p
    /// The page's main content.
    case main
    /// A standalone section of the document.
    case section
    /// A self-contained composition, such as a blog post.
    case article
    /// Content tangentially related to the surrounding content.
    case aside
    /// Introductory content for its nearest sectioning ancestor.
    case header
    /// Footer content for its nearest sectioning ancestor.
    case footer
    /// A section of navigation links.
    case nav
    /// A generic inline container.
    case span
    /// A generic block container.
    case div
    /// An element named by the caller rather than by this enum.
    ///
    /// Prefer the named cases where one exists. Names given here are validated
    /// against ``HTMLElement/isValidName(_:)`` when the element is emitted;
    /// invalid names are rejected rather than written into the document.
    case custom(String)

    /// The element's tag name as it appears in the emitted markup.
    public var name: String {
        switch self {
            case .h1: "h1"
            case .h2: "h2"
            case .h3: "h3"
            case .h4: "h4"
            case .h5: "h5"
            case .h6: "h6"
            case .p: "p"
            case .main: "main"
            case .section: "section"
            case .article: "article"
            case .aside: "aside"
            case .header: "header"
            case .footer: "footer"
            case .nav: "nav"
            case .span: "span"
            case .div: "div"
            case .custom(let name): name
        }
    }

    /// Whether the element is a void element, i.e. one that must not be given
    /// a closing tag.
    public var isVoid: Bool {
        Self.voidElementNames.contains(name)
    }

    /// Whether the element's name is usable in an emitted document.
    ///
    /// The named cases are always valid. ``HTMLElement/custom(_:)`` is valid
    /// only if its name matches the HTML spec's shape for a custom element
    /// name: an ASCII letter followed by ASCII alphanumerics and hyphens.
    public var isValid: Bool {
        switch self {
            case .custom(let name): Self.isValidName(name)
            default: true
        }
    }

    /// Checks whether a string is usable as an HTML element name.
    ///
    /// This is deliberately stricter than the HTML spec, which permits a wide
    /// range of characters in tag names. Static output benefits more from
    /// rejecting typos than from accepting exotic names.
    ///
    /// - Parameter name: The candidate element name.
    /// - Returns: Whether `name` may be emitted as an element name.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter else {
            return false
        }
        return name.dropFirst().allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-")
        }
    }

    private static let voidElementNames: Set<String> = [
        "area",
        "base",
        "br",
        "col",
        "embed",
        "hr",
        "img",
        "input",
        "link",
        "meta",
        "source",
        "track",
        "wbr",
    ]
}
