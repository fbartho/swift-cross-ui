import SwiftCrossUI

extension View {
    /// Contributes document machinery — a script, a stylesheet, a meta tag —
    /// that this view needs the emitted document to carry.
    ///
    /// Registration is idempotent per dedupe key, so a component used fifty
    /// times on a page contributes its stylesheet once. Items reach the
    /// document in first-appearance order within their slot, always before
    /// anything the page owner registered on the ``DocumentContext``.
    ///
    /// This modifier only affects StaticHTMLBackend. Under any other backend
    /// there is no registry in the environment and the call does nothing, so a
    /// view hierarchy carrying it stays portable.
    ///
    /// - Parameters:
    ///   - content: The item to contribute.
    ///   - slot: Where in the document it should land.
    ///   - id: An identity for deduplication, overriding the one derived from
    ///     the content (its URL, or a hash of it).
    /// - Returns: The view, contributing the item whenever it renders.
    public func htmlDocumentItem(
        _ content: HTMLDocumentItemContent,
        slot: HTMLDocumentItem.Slot = .head,
        id: String? = nil
    ) -> some View {
        htmlDocumentItems([HTMLDocumentItem(content, slot: slot, id: id)])
    }

    /// Contributes several fragment items at once.
    ///
    /// - Parameter items: The items to contribute.
    /// - Returns: The view, contributing the items whenever it renders.
    public func htmlDocumentItems(_ items: [HTMLDocumentItem]) -> some View {
        HTMLDocumentContributionView(items: items, content: self)
    }
}

/// A protocol that a component conforms to when it always needs the same
/// document machinery.
///
/// Pure sugar over ``SwiftCrossUI/View/htmlDocumentItem(_:slot:id:)``: conforming
/// and listing the items is equivalent to applying the modifier to the body,
/// and it reads better on a component whose assets are part of what it is.
///
/// ```swift
/// struct SyntaxHighlightedCode: HTMLDocumentContributing {
///     var documentItems: [HTMLDocumentItem] {
///         [HTMLDocumentItem(.stylesheet(href: "/css/highlight.css"), slot: .head)]
///     }
///
///     var body: some View { contributingBody { … } }
/// }
/// ```
///
/// Note that this can only be conformed to by types the author owns. A
/// retroactive conformance on a view the core defines would never fire: the
/// core's update loop knows nothing about this protocol, so nothing would
/// consult it. Machinery for the core's own views is registered by the emitter
/// instead, when it emits one.
///
/// ## Items that vary with the environment
///
/// Reading `@Environment` to decide what to contribute is supported: the
/// wrapper is populated before `body` runs, from the same snapshot `body` sees,
/// and this getter runs inside that window. A component that contributes
/// different items under different conditions works.
///
/// What needs care is content that varies while its *key* doesn't. A document
/// renders twice, once per color scheme, and both passes register into one
/// registry that keeps the first item per key. So an item whose content is
/// built from `\.colorScheme` but whose key is invariant contributes its light
/// variant and silently drops its dark one.
///
/// Two shapes are safe: content that is identical across the two passes (use
/// `light-dark()` or a media query to express the difference in CSS rather than
/// in Swift), or a key derived from the varying value, so each variant gets its
/// own slot. ``GeometrySelector`` takes the second route.
///
/// A debug build traps on a collision whose content differs, so this is a
/// caught mistake rather than a missing asset noticed in production.
@MainActor
public protocol HTMLDocumentContributing: View {
    /// The items this component needs the document to carry.
    var documentItems: [HTMLDocumentItem] { get }
}

extension HTMLDocumentContributing {
    /// Wraps a body so that this component's ``documentItems`` are contributed
    /// whenever it renders.
    ///
    /// - Parameter content: The component's actual body.
    /// - Returns: That body, contributing the component's items.
    public func contributingBody(@ViewBuilder _ content: () -> some View) -> some View {
        content().htmlDocumentItems(documentItems)
    }
}

/// The view that performs a contribution.
///
/// A view rather than a bare `transformEnvironment` because registering is an
/// effect on a reference type, not a change to what descendants see: the
/// registry instance in the environment is the renderer's, and this only needs
/// to reach it once per update. Reading it in a `transformEnvironment` closure
/// would work too, but it would misrepresent the intent — nothing about the
/// environment below this view differs.
struct HTMLDocumentContributionView<Content: View>: View {
    /// The items to register.
    var items: [HTMLDocumentItem]
    /// The view being modified.
    var content: Content

    var body: some View {
        content.transformEnvironment(\.htmlFragmentRegistry) { registry in
            // Nil under every other backend, which is what makes the whole
            // surface a portable no-op rather than something callers have to
            // conditionalize.
            guard let registry else {
                return
            }
            for item in items {
                registry.register(item)
            }
        }
    }
}
