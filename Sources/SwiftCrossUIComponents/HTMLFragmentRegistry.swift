import SwiftCrossUI

/// Collects the document machinery a render pass asks for.
///
/// This is a reference type because it accumulates across the pass: the
/// renderer seeds one, every registration surface writes into that same
/// instance, and emission drains it into the document. A value type would hand
/// each view its own copy and lose everything.
///
/// ## Idempotency, and why it spans tiers
///
/// Registration keeps the first item seen per ``HTMLDocumentItem/DedupeKey`` — a
/// component that renders in fifty places contributes its script once. The same
/// contract is what lets a future runtime backend reuse this type verbatim: a
/// live registry checks the document for an element already carrying
/// `data-scui-head-id="<key>"` before inserting, so a component rendered on a
/// runtime-only path injects its script then, while one whose script the static
/// build already emitted finds the marker and does nothing. One API, idempotent
/// on both sides of the build-time/runtime boundary.
@MainActor
public final class HTMLFragmentRegistry {
    /// The registered items, in the order their keys were first seen.
    private var items: [HTMLDocumentItem] = []
    /// The position in `items` of the item registered under each key.
    private var indicesByKey: [HTMLDocumentItem.DedupeKey: Int] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Registers an item, unless its key is already spoken for.
    ///
    /// - Parameter item: The item to register.
    /// - Returns: Whether the item was added, as opposed to deduplicated away
    ///   against an earlier registration under the same key.
    @discardableResult
    public func register(_ item: HTMLDocumentItem) -> Bool {
        precondition(
            item.content.allows(item.slot),
            """
            \(item.content.kindName) can't be emitted into \(item.slot.debugName). \
            Its content kind is only legal in \
            \(item.content.allowedSlots?.map(\.debugName).sorted()
                .joined(separator: ", ") ?? "any slot").
            """
        )

        guard let existingIndex = indicesByKey[item.key] else {
            indicesByKey[item.key] = items.count
            items.append(item)
            return true
        }

        // Two registrations sharing a derived key but not their content mean
        // the second one never reaches the document. Dropping it is the
        // contract, so this can't throw — but the drop is invisible in the
        // output, and the shape that causes it (content varying across the
        // light/dark passes that share this registry) looks correct at the call
        // site. Catching it in debug is the only place the mistake is legible.
        //
        // An `.id` key is exempt because overriding is what it's for: the
        // author asserting two different items are one, so the first wins.
        assert(
            item.key.isAuthorSupplied || items[existingIndex].content == item.content,
            """
            Two different items registered under \(item.key.debugName). The \
            first one wins and this one is dropped, so the document will carry \
            \(items[existingIndex].content.kindName.lowercased()) that isn't \
            the one this registration asked for.

            The usual cause is content that varies with the environment: the \
            light and dark render passes share one registry, so an item whose \
            key doesn't vary but whose content is built from \\.colorScheme \
            silently loses its second variant. Either make the content \
            invariant across the passes, or derive the key from the varying \
            value so each variant gets its own slot.

            Where replacing the earlier item is the intent, say so with an \
            explicit `id:`, which is exempt from this check.
            """
        )
        return false
    }

    /// Registers an item built from content and a slot.
    ///
    /// - Parameters:
    ///   - content: The item itself.
    ///   - slot: Where to emit it.
    ///   - id: An author-supplied identity, overriding the derived dedupe key.
    /// - Returns: Whether the item was added.
    @discardableResult
    public func register(
        _ content: HTMLDocumentItemContent,
        slot: HTMLDocumentItem.Slot,
        id: String? = nil
    ) -> Bool {
        register(HTMLDocumentItem(content, slot: slot, id: id))
    }

    /// Whether an item is already registered under a key.
    ///
    /// - Parameter key: The key to check.
    /// - Returns: Whether the key is spoken for.
    public func contains(_ key: HTMLDocumentItem.DedupeKey) -> Bool {
        indicesByKey[key] != nil
    }

    /// The items registered for a slot, in first-appearance order.
    ///
    /// - Parameter slot: The slot to collect.
    /// - Returns: That slot's items.
    public func items(in slot: HTMLDocumentItem.Slot) -> [HTMLDocumentItem] {
        items.filter { $0.slot == slot }
    }

    /// Every registered item, in first-appearance order.
    public var allItems: [HTMLDocumentItem] {
        items
    }
}

extension EnvironmentValues {
    /// The registry that view-tree contributions register document machinery
    /// into.
    ///
    /// Only StaticHTMLBackend seeds this. Under any other backend it stays
    /// `nil`, which makes every registration surface a no-op, so a view
    /// hierarchy that contributes document items stays portable.
    @Entry public var htmlFragmentRegistry: HTMLFragmentRegistry?
}

extension HTMLDocumentItemContent {
    /// A human-readable name for the content kind, for diagnostics.
    var kindName: String {
        switch self {
            case .script: "A script"
            case .inlineScript: "An inline script"
            case .stylesheet: "A stylesheet link"
            case .style: "An inline style"
            case .meta: "A meta tag"
            case .rawHTML: "A raw HTML fragment"
            case .stylesheetBytes: "A stylesheet carried as bytes"
            case .scriptBytes: "A script carried as bytes"
        }
    }
}

extension HTMLDocumentItem.Slot {
    /// A human-readable name for the slot, for diagnostics.
    var debugName: String {
        switch self {
            case .head: ".head"
            case .bodyEnd: ".bodyEnd"
            case .custom(let name): ".custom(\"\(name)\")"
        }
    }
}

extension HTMLDocumentItem.DedupeKey {
    /// Whether the author chose this key rather than it being derived from the
    /// content.
    ///
    /// An author-chosen key is a claim about identity that outranks what the
    /// content says, which is what makes deliberate replacement possible.
    var isAuthorSupplied: Bool {
        if case .id = self { true } else { false }
    }

    /// A human-readable name for the key, for diagnostics.
    var debugName: String {
        switch self {
            case .url(let url): ".url(\"\(url)\")"
            case .id(let id): ".id(\"\(id)\")"
            case .contentHash(let hash): ".contentHash(\"\(hash)\")"
        }
    }
}
