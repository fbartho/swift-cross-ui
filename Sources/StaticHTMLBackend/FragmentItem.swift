import Foundation
import SwiftCrossUI

/// A piece of document machinery — a script, a stylesheet, a meta tag — that
/// something in the view tree needs the emitted document to carry.
///
/// The item is placement-generic rather than head-specific: a script or a
/// stylesheet is legal in several places, so the item names what it *is* and
/// the content kind carries its own placement validity (see
/// ``FragmentContent/allowedSlots``). A meta tag, which the HTML parser only
/// honors inside `<head>`, is rejected at registration if it's aimed anywhere
/// else rather than emitted somewhere it would be silently ignored.
public struct FragmentItem: Hashable, Sendable {
    /// What distinguishes this item from every other one.
    public var key: DedupeKey
    /// Where in the document the item should be emitted.
    public var slot: Slot
    /// The item itself.
    public var content: FragmentContent

    /// Creates an item with an explicit dedupe key.
    ///
    /// - Parameters:
    ///   - key: The item's dedupe key.
    ///   - slot: Where to emit the item.
    ///   - content: The item itself.
    public init(key: DedupeKey, slot: Slot, content: FragmentContent) {
        self.key = key
        self.slot = slot
        self.content = content
    }

    /// Creates an item, deriving its dedupe key from its content.
    ///
    /// A `src`-based item keys off its URL, so the same script registered by
    /// two unrelated components collapses to one tag. Anything carrying inline
    /// content keys off a hash of that content, so two components that
    /// independently register byte-identical CSS collapse too, while two that
    /// register different CSS both survive.
    ///
    /// Pass `id` when neither rule expresses the intent — two builds of the
    /// same logical asset at different URLs, say, or inline content that should
    /// be replaceable by a later registration.
    ///
    /// - Parameters:
    ///   - content: The item itself.
    ///   - slot: Where to emit the item.
    ///   - id: An author-supplied identity, which overrides the derived key.
    public init(_ content: FragmentContent, slot: Slot, id: String? = nil) {
        self.init(
            key: id.map(DedupeKey.id) ?? content.derivedKey,
            slot: slot,
            content: content
        )
    }

    /// What makes two items the same item.
    ///
    /// Registration is idempotent per key: the first item registered under a
    /// key wins and later ones are dropped, so a component that renders a
    /// hundred times contributes its script once. The reserved keys are the
    /// exception — see ``DedupeKey/reset``.
    public enum DedupeKey: Hashable, Sendable {
        /// The item is identified by the URL it references.
        case url(String)
        /// The item is identified by a name its author chose.
        case id(String)
        /// The item is identified by a hash of its own content.
        case contentHash(String)
    }

    /// Where an item lands in the emitted document.
    public enum Slot: Hashable, Sendable {
        /// Inside `<head>`.
        case head
        /// At the end of `<body>`, after the rendered content.
        case bodyEnd
        /// A slot the page owner defined, marked in the tree by a
        /// ``SlotComponent``.
        case custom(String)
    }
}

/// The kinds of machinery a ``FragmentItem`` can carry.
///
/// Each case knows where it is legal, so placement is a property of the content
/// rather than a convention callers have to remember.
public enum FragmentContent: Hashable, Sendable {
    /// An external script, referenced by URL.
    case script(src: String, attributes: [String: String] = [:])
    /// A script whose source is written inline.
    case inlineScript(String)
    /// An external stylesheet, referenced by URL.
    case stylesheet(href: String)
    /// A stylesheet written inline.
    case style(String)
    /// A meta tag, given as its attributes.
    case meta([String: String])
    /// Markup spliced in verbatim, with no escaping and no validation.
    ///
    /// The same caller-trusted stance as ``RawHTMLFragment``: whatever is
    /// written here reaches the document unchanged.
    case rawHTML(String)

    /// The slots this content may be emitted into.
    ///
    /// `nil` means the content is legal anywhere. A meta tag is the case that
    /// isn't: the parser only honors it inside `<head>`, so aiming one at
    /// `bodyEnd` is a mistake worth catching rather than markup worth emitting.
    public var allowedSlots: Set<FragmentItem.Slot>? {
        switch self {
            case .meta:
                [.head]
            case .script, .inlineScript, .stylesheet, .style, .rawHTML:
                nil
        }
    }

    /// Whether this content may be emitted into a slot.
    ///
    /// - Parameter slot: The slot in question.
    /// - Returns: Whether the content is legal there.
    public func allows(_ slot: FragmentItem.Slot) -> Bool {
        allowedSlots?.contains(slot) ?? true
    }

    /// The dedupe key this content implies when the author supplies none.
    var derivedKey: FragmentItem.DedupeKey {
        switch self {
            case let .script(src, _):
                .url(src)
            case let .stylesheet(href):
                .url(href)
            case let .inlineScript(source):
                .contentHash(Self.hash(of: "script:" + source))
            case let .style(css):
                .contentHash(Self.hash(of: "style:" + css))
            case let .rawHTML(html):
                .contentHash(Self.hash(of: "raw:" + html))
            case let .meta(attributes):
                .contentHash(
                    Self.hash(
                        of: "meta:"
                            + attributes
                            .sorted { $0.key < $1.key }
                            .map { "\($0.key)=\($0.value)" }
                            .joined(separator: "&")
                    )
                )
        }
    }

    /// Hashes a string into a short, stable hex digest.
    ///
    /// Stability across processes is what matters here, so this can't use
    /// `Hasher`: Swift seeds that per-process, which would give the same
    /// content a different dedupe key on every build and, worse, a different
    /// `data-scui-head-id` than the one a runtime tier looks for. FNV-1a is
    /// small, dependency-free, and deterministic — and since the only thing
    /// riding on it is collapsing identical registrations, it doesn't need to
    /// resist an adversary.
    static func hash(of string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }
}

extension FragmentItem.DedupeKey {
    /// The key the emitter's own baseline stylesheet registers itself under.
    ///
    /// Registering an item under this key before the reset would have been
    /// added replaces it, because the registry keeps the first item per key and
    /// the emitter registers its own late. That makes dropping the baseline a
    /// deliberate, visible act in the page owner's code rather than something
    /// that can happen by accident.
    public static let reset = FragmentItem.DedupeKey.id("scui-reset")

    /// The identity written into an emitted item's `data-scui-head-id`.
    ///
    /// A runtime tier checks the document for this marker before injecting the
    /// same item, so build-time and runtime registration of one asset resolve
    /// to a single tag. See the registry's cross-tier note.
    public var markerValue: String {
        switch self {
            case let .url(url):
                "url:\(url)"
            case let .id(id):
                "id:\(id)"
            case let .contentHash(hash):
                "sha:\(hash)"
        }
    }
}
