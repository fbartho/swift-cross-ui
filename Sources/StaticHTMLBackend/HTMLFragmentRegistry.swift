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
/// Registration keeps the first item seen per ``FragmentItem/DedupeKey`` — a
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
    private var items: [FragmentItem] = []
    /// The position in `items` of the item registered under each key.
    private var indicesByKey: [FragmentItem.DedupeKey: Int] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Registers an item, unless its key is already spoken for.
    ///
    /// - Parameter item: The item to register.
    /// - Returns: Whether the item was added, as opposed to deduplicated away
    ///   against an earlier registration under the same key.
    @discardableResult
    public func register(_ item: FragmentItem) -> Bool {
        precondition(
            item.content.allows(item.slot),
            """
            \(item.content.kindName) can't be emitted into \(item.slot.debugName). \
            Its content kind is only legal in \
            \(item.content.allowedSlots?.map(\.debugName).sorted()
                .joined(separator: ", ") ?? "any slot").
            """
        )

        guard indicesByKey[item.key] == nil else {
            return false
        }
        indicesByKey[item.key] = items.count
        items.append(item)
        return true
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
        _ content: FragmentContent,
        slot: FragmentItem.Slot,
        id: String? = nil
    ) -> Bool {
        register(FragmentItem(content, slot: slot, id: id))
    }

    /// Whether an item is already registered under a key.
    ///
    /// - Parameter key: The key to check.
    /// - Returns: Whether the key is spoken for.
    public func contains(_ key: FragmentItem.DedupeKey) -> Bool {
        indicesByKey[key] != nil
    }

    /// The items registered for a slot, in first-appearance order.
    ///
    /// - Parameter slot: The slot to collect.
    /// - Returns: That slot's items.
    public func items(in slot: FragmentItem.Slot) -> [FragmentItem] {
        items.filter { $0.slot == slot }
    }

    /// Every registered item, in first-appearance order.
    public var allItems: [FragmentItem] {
        items
    }
}

extension EnvironmentValues {
    /// The registry that view-tree contributions register document machinery
    /// into.
    ///
    /// Only StaticHTMLBackend seeds this. Under any other backend it stays
    /// `nil`, which makes every registration surface a no-op, so a view
    /// hierarchy that contributes head items stays portable.
    @Entry public var htmlFragmentRegistry: HTMLFragmentRegistry?
}

extension FragmentContent {
    /// A human-readable name for the content kind, for diagnostics.
    var kindName: String {
        switch self {
            case .script: "A script"
            case .inlineScript: "An inline script"
            case .stylesheet: "A stylesheet link"
            case .style: "An inline style"
            case .meta: "A meta tag"
            case .rawHTML: "A raw HTML fragment"
        }
    }
}

extension FragmentItem.Slot {
    /// A human-readable name for the slot, for diagnostics.
    var debugName: String {
        switch self {
            case .head: ".head"
            case .bodyEnd: ".bodyEnd"
            case .custom(let name): ".custom(\"\(name)\")"
        }
    }
}
