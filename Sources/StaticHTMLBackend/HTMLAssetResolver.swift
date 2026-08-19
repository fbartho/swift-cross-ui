import Foundation
import SwiftCrossUIComponents

/// Turns asset bytes into the reference a document carries for them.
///
/// Publishing is the policy. A data URL carries the bytes on every page that
/// uses them, uncached, at roughly a third more than the file — so inlining is
/// the fallback for renders with nowhere to publish to (tests, previews,
/// anything that has to be self-contained) rather than the default.
///
/// Small assets invert that arithmetic: an icon costs more as a request than as
/// bytes, so anything at or under the configured threshold stays inline even
/// where a store exists.
///
/// Every byte-carrying surface resolves through here — images, stylesheets,
/// scripts — so one set of rules decides disposition for all of them.
@MainActor
struct HTMLAssetResolver {
    /// The stores bytes can be published into.
    var stores: HTMLAssetStores
    /// The size at or below which bytes inline despite a store existing.
    var inlineThreshold: Int?

    /// Resolves bytes to the URL or data URL a document should reference.
    ///
    /// - Parameters:
    ///   - data: The asset's bytes.
    ///   - fileExtension: The extension a published file should carry.
    ///   - mediaType: The MIME type a data URL should declare.
    ///   - disposition: What the registration asked for.
    ///   - store: Which store to publish into, or `nil` for the default.
    /// - Returns: A URL where the bytes were published, or a data URL carrying
    ///   them.
    func reference(
        for data: [UInt8],
        fileExtension: String,
        mediaType: String,
        disposition: HTMLAssetDisposition,
        store name: String?
    ) -> String {
        func inlined() -> String {
            "data:\(mediaType);base64,\(Data(data).base64EncodedString())"
        }

        switch disposition {
            case .inline:
                return inlined()
            case .published:
                // An explicit request to publish still degrades rather than
                // breaking the page: a document referencing a file no store
                // wrote would 404.
                return stores.publish(data, fileExtension: fileExtension, store: name)
                    ?? inlined()
            case .automatic:
                if let inlineThreshold, data.count <= inlineThreshold {
                    return inlined()
                }
                return stores.publish(data, fileExtension: fileExtension, store: name)
                    ?? inlined()
        }
    }
}
