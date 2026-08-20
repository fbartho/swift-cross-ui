import SwiftCrossUI

/// Somewhere to publish binary assets that the document references by URL.
///
/// Inlining an asset as a data URL costs roughly a third more bytes than the
/// file, and costs them on every page that carries it, uncached. Publishing to
/// a store is therefore the policy and inlining the fallback.
///
/// Implementations are expected to name files by a hash of their content, which
/// buys deduplication (one file no matter how many pages use the asset) and
/// safe far-future caching (changed bytes are a different URL).
///
/// Publishing is synchronous because it happens inside a render, which is
/// MainActor-bound. Work that needs to be asynchronous — minification, asset
/// compilation — belongs in a build stage outside the render loop, which then
/// hands the finished bytes here.
@MainActor
public protocol HTMLAssetStore: AnyObject {
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
    ///   store degrades to a working document rather than a missing asset.
    func publish(_ data: [UInt8], fileExtension: String) -> String?
}

/// The stores a render can publish into, addressed by name.
///
/// A render always has at most one default store, and may have any number of
/// named ones. The default is what an unqualified publish reaches, which is
/// what keeps the common case — one output directory — free of naming
/// ceremony; named stores exist for the site that routes some assets
/// elsewhere (a CDN bucket, a versioned directory) and has to say which.
///
/// Lookup falls back to the default when a name isn't registered, so a
/// component asking for a store the site didn't configure still publishes
/// rather than silently emitting nothing.
@MainActor
public struct HTMLAssetStores {
    /// The store an unqualified publish reaches.
    public var `default`: (any HTMLAssetStore)?
    /// The stores a publish can address by name.
    public var named: [String: any HTMLAssetStore]

    /// Creates a set of stores.
    ///
    /// - Parameters:
    ///   - default: The store an unqualified publish reaches.
    ///   - named: The stores addressable by name.
    public init(
        default defaultStore: (any HTMLAssetStore)? = nil,
        named: [String: any HTMLAssetStore] = [:]
    ) {
        self.default = defaultStore
        self.named = named
    }

    /// The store a publish should go to.
    ///
    /// - Parameter name: The store's name, or `nil` for the default.
    /// - Returns: The named store, the default where the name is unregistered,
    ///   or `nil` when the render has nowhere to publish at all.
    public func store(named name: String?) -> (any HTMLAssetStore)? {
        guard let name else {
            return `default`
        }
        return named[name] ?? `default`
    }

    /// Whether the render has anywhere to publish.
    public var isEmpty: Bool {
        `default` == nil && named.isEmpty
    }

    /// Publishes bytes into one of these stores.
    ///
    /// - Parameters:
    ///   - data: The asset's bytes.
    ///   - fileExtension: The extension the file should carry, without a dot.
    ///   - store: Which store to publish into, or `nil` for the default.
    /// - Returns: The URL to reference the asset by, or `nil` where there was
    ///   no store to publish into or the store declined.
    public func publish(
        _ data: [UInt8],
        fileExtension: String,
        store name: String? = nil
    ) -> String? {
        store(named: name)?.publish(data, fileExtension: fileExtension)
    }
}

extension EnvironmentValues {
    /// The stores a view may publish bytes into, receiving a URL to reference
    /// them by.
    ///
    /// Only StaticHTMLBackend seeds this, at the render root. Under any other
    /// backend it stays `nil`, so ``publishHTMLAsset(_:fileExtension:store:)``
    /// returns `nil` and a view hierarchy that publishes assets stays portable.
    @Entry public var htmlAssetStores: HTMLAssetStores?

    /// Publishes bytes and returns the URL the document should reference them
    /// by.
    ///
    /// The URL is in hand immediately, so a view can weave it into markup it is
    /// about to emit — an `href`, a `srcset`, a CSS `url()` — rather than only
    /// into a document item.
    ///
    /// - Parameters:
    ///   - data: The asset's bytes.
    ///   - fileExtension: The extension the file should carry, without a dot.
    ///   - store: Which store to publish into, or `nil` for the default.
    /// - Returns: The URL to reference the asset by, or `nil` under a backend
    ///   with no store configured — in which case the caller decides whether to
    ///   inline the bytes or emit nothing.
    @MainActor
    public func publishHTMLAsset(
        _ data: [UInt8],
        fileExtension: String,
        store name: String? = nil
    ) -> String? {
        htmlAssetStores?.publish(data, fileExtension: fileExtension, store: name)
    }
}
