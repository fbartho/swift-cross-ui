import Foundation
import SwiftCrossUI

/// Everything the page owner gets to say about the document being assembled.
///
/// The view tree describes content; this describes the document that carries
/// it. Both the title and the heading derivation used to be loose parameters on
/// ``StaticHTMLRenderer/render(_:context:size:)`` — they live here now because
/// they answer the same question every other member does ("what document is
/// this?"), and keeping them together means the page owner passes one value
/// rather than a growing parameter list.
///
/// The page owner has the final say by construction: its items emit after every
/// contribution the view tree made, so a stylesheet registered here overrides
/// one a component asked for.
@MainActor
public struct DocumentContext {
    /// The document's title.
    public var title: String
    /// The mapping used to derive headings from declared text styles.
    public var headingMap: HeadingMap
    /// The language written into `<html lang>`.
    public var language: String
    /// The page owner's own items, emitted after every contribution.
    public var items: [FragmentItem]
    /// The names of the slots ``SlotComponent`` may reference.
    ///
    /// Declaring a slot is what makes it addressable: a ``SlotComponent`` for a
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

    /// Creates a document context.
    ///
    /// - Parameters:
    ///   - title: The document's title.
    ///   - headingMap: The mapping to derive headings with.
    ///   - language: The language for `<html lang>`.
    ///   - items: The page owner's own fragment items.
    ///   - customSlots: The names of slots ``SlotComponent`` may reference.
    ///   - assetStore: Where to publish image data, or `nil` to inline it.
    ///   - inlineAssetThreshold: The byte size at or below which an image is
    ///     inlined even when a store is configured.
    public init(
        title: String,
        headingMap: HeadingMap = .default,
        language: String = "en",
        items: [FragmentItem] = [],
        customSlots: Set<String> = [],
        assetStore: (any AssetStore)? = nil,
        inlineAssetThreshold: Int? = nil
    ) {
        self.title = title
        self.headingMap = headingMap
        self.language = language
        self.items = items
        self.customSlots = customSlots
        self.assetStore = assetStore
        self.inlineAssetThreshold = inlineAssetThreshold
    }

    /// Adds an item to the page owner's own items.
    ///
    /// - Parameters:
    ///   - content: The item itself.
    ///   - slot: Where to emit it.
    ///   - id: An author-supplied identity, overriding the derived dedupe key.
    /// - Returns: The context, carrying the added item.
    public func with(
        _ content: FragmentContent,
        slot: FragmentItem.Slot,
        id: String? = nil
    ) -> DocumentContext {
        var copy = self
        copy.items.append(FragmentItem(content, slot: slot, id: id))
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
        let digest = FragmentContent.hash(of: Self.digestInput(for: data))
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
