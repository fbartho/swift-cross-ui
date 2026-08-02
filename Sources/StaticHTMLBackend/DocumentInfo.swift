/// A standard document metadata key, mapped onto its conventional
/// `<meta name>` value.
///
/// The enum cases cover the metadata that comes up when a page owner
/// registers `<meta>` tags for SEO or social sharing. Names outside this list
/// are still reachable via ``DocumentInfoKey/custom(_:)`` — the same shape as
/// ``HTMLElement``: an exhaustive-ish set of named cases, open for caller
/// extension, so a consumer can switch over the common ones and fall back to
/// the raw name for everything else.
public enum DocumentInfoKey: Hashable, Sendable {
    /// The document's title.
    case title
    /// The document's description, conventionally `<meta name="description">`.
    case description
    /// The document's author, conventionally `<meta name="author">`.
    case author
    /// The document's canonical URL, conventionally
    /// `<link rel="canonical">` — carried here as a metadata value rather
    /// than requiring a consumer to special-case the differing element.
    case canonicalURL
    /// A key named by the caller rather than by this enum.
    ///
    /// Prefer the named cases where one exists. Holds the meta tag's `name`
    /// (or `property`, for Open Graph-style tags) attribute verbatim.
    case custom(String)

    /// The conventional `<meta name>` (or `property`) value this key maps
    /// onto.
    public var rawName: String {
        switch self {
            case .title: "title"
            case .description: "description"
            case .author: "author"
            case .canonicalURL: "canonical"
            case .custom(let name): name
        }
    }

    /// Maps a registered meta tag's `name` (or `property`) attribute onto a
    /// standard key, falling back to ``DocumentInfoKey/custom(_:)`` for
    /// anything not in the standard set.
    ///
    /// - Parameter rawName: The attribute value to map.
    /// - Returns: The matching standard key, or `.custom(rawName)`.
    public static func standardOrCustom(_ rawName: String) -> DocumentInfoKey {
        Self.standardByRawName[rawName] ?? .custom(rawName)
    }

    /// Every named case, keyed by its raw name — built once rather than on
    /// each lookup.
    private static let standardByRawName: [String: DocumentInfoKey] = [
        title.rawName: .title,
        description.rawName: .description,
        author.rawName: .author,
        canonicalURL.rawName: .canonicalURL,
    ]
}

/// A rendered document's structured self-description: its title, heading
/// outline, and registered metadata — everything a consumer like a sitemap
/// builder needs without parsing the emitted HTML.
///
/// Every field here already exists as a value inside the render (the title on
/// ``DocumentContext``, the heading elements ``HeadingMap`` derives, the
/// ``FragmentItem``s registered as `.meta`); this struct just carries them out
/// of the render alongside the markup instead of discarding them once emitted.
public struct DocumentInfo: Hashable, Sendable {
    /// The document's title, as given to ``DocumentContext``.
    public var title: String
    /// The document's heading outline, in document order.
    ///
    /// Derived the same way the emitted markup is: from ``HeadingMap``
    /// mapping a `Text`'s declared font onto a heading element, not from
    /// font size, weight, or position. A page whose structure comes entirely
    /// from explicit ``View/htmlTag(_:)`` calls rather than declared text
    /// styles produces an empty outline — headings named that way carry no
    /// signal this derivation reads.
    public var headings: [Heading]
    /// The document's registered `<meta>` items, keyed by standard key where
    /// one matches and ``DocumentInfoKey/custom(_:)`` otherwise.
    ///
    /// A meta item registering more than one attribute (rare — most carry
    /// just `name`/`property` and `content`) contributes its `content` value
    /// under every recognized name/property key it declared.
    public var metadata: [DocumentInfoKey: String]
    /// The view type tag of every `Image` that emitted `alt=""` for lack of
    /// an author-supplied `alt`, in document order.
    ///
    /// See ``StaticHTMLBackend/ImageView`` for why the fallback exists and
    /// why nothing else can detect it: an empty `alt` an author deliberately
    /// set for a decorative image is indistinguishable, in the markup, from
    /// one this default produced. This is the one place that distinction
    /// still exists. A page owner who wants every image described can check
    /// this list is empty; a component library can log it in development.
    public var imagesMissingAltText: [String]

    /// One entry in a document's heading outline.
    public struct Heading: Hashable, Sendable {
        /// The heading level, 1 for `h1` through 6 for `h6`.
        public var level: Int
        /// The heading's text content.
        public var text: String

        /// Creates a heading outline entry.
        ///
        /// - Parameters:
        ///   - level: The heading level, 1 for `h1` through 6 for `h6`.
        ///   - text: The heading's text content.
        public init(level: Int, text: String) {
            self.level = level
            self.text = text
        }
    }

    /// Creates a document info value.
    ///
    /// - Parameters:
    ///   - title: The document's title.
    ///   - headings: The document's heading outline, in document order.
    ///   - metadata: The document's registered metadata.
    ///   - imagesMissingAltText: The view type tags of images that emitted
    ///     `alt=""` for lack of an author-supplied `alt`.
    public init(
        title: String,
        headings: [Heading] = [],
        metadata: [DocumentInfoKey: String] = [:],
        imagesMissingAltText: [String] = []
    ) {
        self.title = title
        self.headings = headings
        self.metadata = metadata
        self.imagesMissingAltText = imagesMissingAltText
    }
}

extension HTMLElement {
    /// This element's heading level, if it's one of `h1` through `h6`.
    var headingLevel: Int? {
        switch self {
            case .h1: 1
            case .h2: 2
            case .h3: 3
            case .h4: 4
            case .h5: 5
            case .h6: 6
            default: nil
        }
    }
}
