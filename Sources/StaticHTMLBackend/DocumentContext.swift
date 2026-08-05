import Foundation
import SwiftCrossUI
import SwiftCrossUIComponents

/// Everything the page owner gets to say about the document being assembled.
///
/// The view tree describes content; this describes the document that carries
/// it. The title and the heading derivation belong here rather than as
/// parameters on ``StaticHTMLRenderer/render(_:context:size:)`` because they
/// answer the same question every other member does ("what document is
/// this?"), and keeping them together means the page owner passes one value
/// rather than a growing parameter list.
///
/// The page owner has the final say by construction: its items emit after every
/// contribution the view tree made, so a stylesheet registered here overrides
/// one a component asked for.
///
/// ## String literal shorthand
///
/// The common case — a page that needs a title and nothing else this type
/// offers — can skip the initializer entirely: ``DocumentContext`` conforms to
/// `ExpressibleByStringLiteral`, so a bare string is usable anywhere a context
/// is expected. `StaticHTMLRenderer.render(view, context: "My Page")` is
/// exactly `DocumentContext(title: "My Page")`; reach for the initializer
/// itself as soon as the document needs to carry anything more.
@MainActor
public struct DocumentContext {
    /// The document's title.
    public var title: String
    /// The mapping used to derive headings from declared text styles.
    public var headingMap: HeadingMap
    /// The language written into `<html lang>`.
    public var language: String
    /// The page owner's own items, emitted after every contribution.
    public var items: [HTMLHeadItem]
    /// The names of the slots ``HTMLSlot`` may reference.
    ///
    /// Declaring a slot is what makes it addressable: a ``HTMLSlot`` for a
    /// name that was never declared is a typo, and this is what lets the
    /// renderer say so instead of emitting an empty hole.
    public var customSlots: Set<String>
    /// Where image data should be published, if anywhere.
    ///
    /// With a store configured, images become files in the site output that the
    /// document references by URL. Without one — tests, previews, any
    /// self-contained render — image data is inlined as a data URL instead. See
    /// ``AssetStore``.
    public var assetStore: (any AssetStore)?
    /// The size at or below which an image is inlined even when a store is
    /// configured.
    ///
    /// Icons and other small images cost more as a request than as bytes, so
    /// they stay inline. `nil` inlines nothing when a store exists.
    ///
    /// The threshold belongs to whoever is publishing the site, not to the
    /// backend, which is why it's a context member with no baked-in default
    /// beyond "don't".
    public var inlineAssetThreshold: Int?
    /// Whether each element carries the `data-scui` attribute naming the view
    /// type it came from.
    ///
    /// On by default: the attribute is what makes the emitted document
    /// legible against the view tree that produced it, which is the whole of
    /// how this backend is debugged, and it is also what the structural
    /// guards in the test suite key on. Turning it off is a size decision for
    /// a published site, taken by whoever publishes it.
    ///
    /// This governs the identity attribute only. The `data-scui-*` protocol
    /// markers — `data-scui-enliven`, the head-item id, the table scroll
    /// marker — are instructions to another tier rather than debug
    /// information, so they are emitted regardless: a document that dropped
    /// them would be silently un-enlivenable.
    public var emitsViewIdentity: Bool

    /// Creates a document context.
    ///
    /// - Parameters:
    ///   - title: The document's title.
    ///   - headingMap: The mapping to derive headings with.
    ///   - language: The language for `<html lang>`.
    ///   - items: The page owner's own fragment items.
    ///   - customSlots: The names of slots ``HTMLSlot`` may reference.
    ///   - assetStore: Where to publish image data, or `nil` to inline it.
    ///   - inlineAssetThreshold: The byte size at or below which an image is
    ///     inlined even when a store is configured.
    ///   - emitsViewIdentity: Whether to write the `data-scui` attribute
    ///     naming each element's view type.
    public init(
        title: String,
        headingMap: HeadingMap = .default,
        language: String = "en",
        items: [HTMLHeadItem] = [],
        customSlots: Set<String> = [],
        assetStore: (any AssetStore)? = nil,
        inlineAssetThreshold: Int? = nil,
        emitsViewIdentity: Bool = true
    ) {
        self.title = title
        self.headingMap = headingMap
        self.language = language
        self.items = items
        self.customSlots = customSlots
        self.assetStore = assetStore
        self.inlineAssetThreshold = inlineAssetThreshold
        self.emitsViewIdentity = emitsViewIdentity
    }

    /// Adds an item to the page owner's own items.
    ///
    /// - Parameters:
    ///   - content: The item itself.
    ///   - slot: Where to emit it.
    ///   - id: An author-supplied identity, overriding the derived dedupe key.
    /// - Returns: The context, carrying the added item.
    public func with(
        _ content: HTMLHeadItemContent,
        slot: HTMLHeadItem.Slot,
        id: String? = nil
    ) -> DocumentContext {
        var copy = self
        copy.items.append(HTMLHeadItem(content, slot: slot, id: id))
        return copy
    }

    /// Declares a custom slot and returns the context carrying it.
    ///
    /// - Parameter name: The slot's name.
    /// - Returns: The context, with the slot declared.
    public func withSlot(_ name: String) -> DocumentContext {
        var copy = self
        copy.customSlots.insert(name)
        return copy
    }
}

// ExpressibleByStringLiteral's requirement is nonisolated, but every member
// this initializer touches (self.init(title:)) is @MainActor, same as the
// type itself — isolating the conformance is the compiler-suggested fix
// rather than a workaround, since a string literal is only ever constructed
// at a Swift call site, never off-actor at runtime.
extension DocumentContext: @MainActor ExpressibleByStringLiteral {
    /// Creates a context carrying only a title, from a string literal.
    ///
    /// See the type's "String literal shorthand" doc section — this exists so
    /// the title-only case reads as a bare string at the call site rather
    /// than requiring the full initializer for what's otherwise a single
    /// value.
    ///
    /// - Parameter value: The document's title.
    public init(stringLiteral value: String) {
        self.init(title: value)
    }
}

/// Somewhere to publish binary assets that the document references by URL.
///
/// Inlining an asset as a data URL costs roughly a third more bytes than the
/// file, and costs them on every page that carries it, uncached. Publishing to
/// a store is therefore the policy and inlining the fallback — the reverse of
/// where this backend started.
///
/// Implementations are expected to name files by a hash of their content, which
/// buys deduplication (one file no matter how many pages use the image) and
/// safe far-future caching (a changed image is a different URL).
@MainActor
public protocol AssetStore: AnyObject {
    /// Publishes an asset and returns the URL the document should reference.
    ///
    /// Implementations must be idempotent: publishing identical bytes twice
    /// yields one file and the same URL both times.
    ///
    /// - Parameters:
    ///   - data: The asset's bytes.
    ///   - fileExtension: The extension the file should carry, without a dot.
    /// - Returns: The URL to reference the asset by, or `nil` if it couldn't be
    ///   published — in which case the caller inlines instead, so a failing
    ///   store degrades to a working document rather than a missing image.
    func publish(_ data: [UInt8], fileExtension: String) -> String?
}

/// An ``AssetStore`` that writes content-hashed files into a directory.
///
/// This is the store an SSG wants: files land in `directory`, and the document
/// references them under `urlPrefix`.
@MainActor
public final class DirectoryAssetStore: AssetStore {
    /// The directory files are written into.
    public let directory: URL
    /// The URL prefix the document references files by.
    public let urlPrefix: String
    /// The URLs already published this run, keyed by content hash, so repeat
    /// publishes of one asset don't re-hit the filesystem.
    private var published: [String: String] = [:]

    /// Creates a store.
    ///
    /// - Parameters:
    ///   - directory: The directory to write files into. Created if absent.
    ///   - urlPrefix: The prefix the document references files by, e.g.
    ///     `"/assets"`.
    public init(directory: URL, urlPrefix: String = "assets") {
        self.directory = directory
        self.urlPrefix = urlPrefix
    }

    /// The names of every file this store wrote, in publish order.
    public private(set) var writtenFileNames: [String] = []

    public func publish(_ data: [UInt8], fileExtension: String) -> String? {
        let digest = HTMLHeadItemContent.hash(of: Self.digestInput(for: data))
        let name = "\(digest).\(fileExtension)"

        if let existing = published[name] {
            return existing
        }

        let url = "\(urlPrefix.isEmpty ? "" : urlPrefix + "/")\(name)"
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appendingPathComponent(name)
            // A content-hashed name that already exists holds the same bytes by
            // construction, so rewriting it would only churn mtimes for
            // whatever watches the output directory.
            if !FileManager.default.fileExists(atPath: destination.path) {
                try Data(data).write(to: destination)
                writtenFileNames.append(name)
            }
        } catch {
            // The document still needs an image. Returning nil sends the caller
            // down the data-URL path, which is worse for page size but is a
            // rendering page rather than a broken one.
            return nil
        }

        published[name] = url
        return url
    }

    /// Builds the string the content digest is taken over.
    ///
    /// FNV-1a runs over UTF-8, so the bytes are mapped into a lossless textual
    /// form rather than being reinterpreted as text — arbitrary binary isn't
    /// valid UTF-8, and lossy-decoding it would collapse distinct images onto
    /// one hash.
    private static func digestInput(for data: [UInt8]) -> String {
        var input = String()
        input.reserveCapacity(data.count * 2)
        for byte in data {
            input.append(Character(UnicodeScalar(0x41 + (byte >> 4))))
            input.append(Character(UnicodeScalar(0x41 + (byte & 0x0f))))
        }
        return input
    }
}
