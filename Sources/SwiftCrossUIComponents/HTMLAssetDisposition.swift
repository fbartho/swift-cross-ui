/// How an asset's bytes should reach the document.
///
/// A registration states a preference rather than a mechanism: whether the
/// bytes become a file the document links to, or ride inside the document as a
/// data URL. Where a preference can't be honored — ``published`` under a render
/// with no store — the bytes inline, so the page renders either way.
public enum HTMLAssetDisposition: Hashable, Sendable {
    /// Publish where a store allows it, inline where the bytes are small
    /// enough to be cheaper carried than fetched.
    ///
    /// The threshold is the page owner's (``DocumentContext``), because it
    /// trades request count against page weight for a particular site rather
    /// than for the backend.
    case automatic
    /// Publish as a file, whatever the size.
    ///
    /// For bytes the site wants cacheable across pages regardless of how small
    /// one copy is.
    case published
    /// Carry the bytes in the document.
    ///
    /// For bytes that must survive the document being moved or served alone,
    /// and for anything first paint blocks on.
    case inline
}
