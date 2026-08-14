import SwiftCrossUI

/// An operation on one HTML attribute, shaped after that attribute's own
/// grammar rather than treating every attribute as an opaque string.
///
/// The case an author reaches for follows the DOM API that manipulates the
/// matching attribute grammar:
///
/// - Token-list attributes (`class`, `rel`, ID-list ARIA attributes like
///   `aria-labelledby`) take ``add(_:)``, ``remove(_:)``, and
///   ``replace(_:with:)``, mirroring `classList`. `remove` and `replace`
///   apply even to a token the backend itself put there — `class`'s interned
///   token included — because a deliberate author op is deliberate; nothing
///   here special-cases "backend tokens are exempt."
/// - The property-map attribute (`style`) takes ``setProperty(_:value:)`` and
///   ``removeProperty(_:)``, mirroring `CSSStyleDeclaration`, and merges
///   per-declaration rather than replacing the whole attribute.
/// - Every other attribute is scalar: plain string literals are `set`/replace
///   per `setAttribute`, available via `ExpressibleByStringLiteral` so
///   `"value"` still works directly in an attributes dictionary.
///
/// There's no static `toggle` — a toggle needs something to toggle against,
/// and nothing here defines that pair statically. A dynamic tier can grow
/// one on the same attribute names later without this type changing shape.
public enum HTMLAttributeOp: Sendable, Equatable, ExpressibleByStringLiteral {
    /// Sets the attribute to this exact string, replacing any existing
    /// value — the scalar case, and the only one a plain string literal
    /// produces.
    case set(String)
    /// Appends a token to a token-list attribute, if not already present.
    case add(String)
    /// Removes a token from a token-list attribute.
    case remove(String)
    /// Replaces one token with another in a token-list attribute. A no-op if
    /// the original token isn't present.
    case replace(String, with: String)
    /// Sets one CSS declaration within the `style` attribute, replacing any
    /// existing value for that property.
    case setProperty(String, value: String)
    /// Removes one CSS declaration from the `style` attribute.
    case removeProperty(String)

    public init(stringLiteral value: String) {
        self = .set(value)
    }
}

/// Distinguishes one application of an escape-hatch modifier from another that
/// happens to carry the same value.
///
/// Two applications of `.htmlTag(.li)` — one on a container, one repeated on
/// each of its children by a `ForEach` — put identical values in scope, and
/// only the leaves ever report them. Comparing values alone can't tell those
/// apart, and they mean different documents: one list element, or one per row.
/// A marker allocated per modifier application can, without making the values
/// themselves reference types.
public struct HTMLApplicationMarker: Sendable, Hashable {
    private let token: Token

    private final class Token: Sendable {}

    /// Creates a marker for one modifier application.
    public init() {
        token = Token()
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.token === rhs.token
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(token))
    }
}

/// An element name paired with the application that requested it.
public struct HTMLTagApplication: Sendable, Hashable {
    /// The requested element.
    public var element: HTMLElement
    /// Which application of ``View/htmlTag(_:)`` asked for it.
    public var marker: HTMLApplicationMarker

    /// Creates a tag application.
    ///
    /// - Parameters:
    ///   - element: The element to emit.
    ///   - marker: The application requesting it.
    public init(element: HTMLElement, marker: HTMLApplicationMarker) {
        self.element = element
        self.marker = marker
    }
}

/// A block of attribute operations an author attached to one view.
///
/// Which element the block lands on is decided by how it is *consumed* during
/// emission — see ``materializes`` — rather than by matching it back to the
/// widget that captured it. The marker it carries only separates one
/// application from another, so a repeated modifier (a `ForEach` body applying
/// the same attributes to every row) stays one application per row.
public struct HTMLAttributeBlock: Sendable, Equatable {
    /// The attribute operations to apply, keyed by attribute name.
    public var attributes: [String: HTMLAttributeOp]
    /// Which application of ``View/htmlAttributes(_:)`` this block came from,
    /// so two applications carrying identical attributes stay
    /// distinguishable — see ``HTMLApplicationMarker``.
    var marker = HTMLApplicationMarker()

    /// Whether this block forces its application site to emit an element of
    /// its own rather than riding down to the first element that survives
    /// elision.
    ///
    /// True exactly when the block names an `id`. An identity referenced from
    /// elsewhere in the document — a fragment link, a label association, a
    /// script — has to land on the node the author designated, not on
    /// whichever descendant elision happened to leave standing. Every other
    /// attribute describes whatever element ends up carrying the content, so
    /// it can ride through wrappers that emit nothing.
    ///
    /// A mixed block resolves as one unit: an `id` alongside other attributes
    /// materializes all of them together, because one block describes one
    /// element.
    public var materializes: Bool {
        attributes.keys.contains("id")
    }

    /// Creates a block of attribute operations.
    ///
    /// - Parameter attributes: The attribute operations, keyed by name.
    public init(attributes: [String: HTMLAttributeOp]) {
        self.attributes = attributes
    }

    /// Layers a block applied inside this one on top of it.
    ///
    /// Merges key-by-key with `inner` winning any conflict — the same
    /// "most specific wins" rule as the CSS cascade or a nested environment
    /// override. Attributes are the escape hatch that merges rather than
    /// replaces: an element carries any number of them at once, so two
    /// stacked applications are two facts that both deserve to reach the
    /// document.
    ///
    /// - Parameter inner: The block applied closer to the content.
    /// - Returns: The combined block.
    func layering(_ inner: HTMLAttributeBlock) -> HTMLAttributeBlock {
        HTMLAttributeBlock(
            attributes: attributes.merging(inner.attributes) { _, innermost in innermost }
        )
    }
}

extension EnvironmentValues {
    /// The element applications requested by ``View/htmlTag(_:)``, outermost
    /// first.
    ///
    /// A tag names the element of the view it was applied to, so each entry
    /// belongs to exactly one element and a nested application does not
    /// replace the one enclosing it — both elements exist, one inside the
    /// other. Only a leaf receives an environment, so the enclosing entries
    /// are what tells the renderer that a container above the leaf was
    /// modified too; a lone value would leave the outer element with nothing
    /// reporting it.
    ///
    /// Each entry carries the application that requested it, so two
    /// applications naming the same element stay distinguishable — see
    /// ``HTMLApplicationMarker``.
    ///
    /// Only StaticHTMLBackend reads this; other backends never do.
    @Entry public var htmlTags: [HTMLTagApplication] = []

    /// The `id`-bearing attribute blocks requested by
    /// ``View/htmlAttributes(_:)``, outermost first.
    ///
    /// Nested the same way as ``htmlTags`` and for the same reason: a block
    /// naming an `id` materializes its own element, so an inner one sits
    /// inside the outer one rather than replacing it. Blocks without an `id`
    /// are not here — they merge into ``htmlAttributes`` instead, since they
    /// describe whichever element survives rather than one of their own.
    @Entry public var htmlIdentifiedAttributes: [HTMLAttributeBlock] = []

    /// Attributes requested by ``View/htmlAttributes(_:)`` that name no `id`.
    ///
    /// Consumed by the first element that survives elision beneath the
    /// application site — see ``HTMLAttributeBlock/materializes``. Stacked
    /// applications merge here rather than nesting, because they all describe
    /// the same surviving element.
    @Entry public var htmlAttributes: HTMLAttributeBlock?

    /// Navigation intent requested by ``View/href(_:)``.
    ///
    /// Unlike the other two, this flows down through everything that isn't a
    /// consumer: an href names a destination, and every href-capable view in
    /// scope navigates there. A consumer removes it from the environment its
    /// own children see, so a link's label never inherits the link's
    /// destination.
    @Entry public var htmlHref: String?
}

extension View {
    /// Emits this view using a specific HTML element.
    ///
    /// Use this when a view's role in the document isn't something the backend
    /// can derive. Deriving semantics from layout or styling would be
    /// guesswork, so anything the backend isn't told about becomes a `div`.
    ///
    /// The modified view emits an element of its own even where it would
    /// otherwise be dropped as an empty wrapper: naming an element is a
    /// request for that element to exist.
    ///
    /// This modifier only affects StaticHTMLBackend. Under any other backend
    /// it does nothing, so a view hierarchy carrying it stays portable.
    ///
    /// - Parameter element: The element to emit the view as.
    /// - Returns: The view, tagged with the requested element.
    public func htmlTag(_ element: HTMLElement) -> some View {
        // Allocated here, where the view value is built, so every propagation
        // of this one application carries the same marker.
        let application = HTMLTagApplication(element: element, marker: HTMLApplicationMarker())
        return transformEnvironment(\.htmlTags) { tags in
            tags.append(application)
        }
    }

    /// Emits this view using an element named by a string.
    ///
    /// Prefer ``View/htmlTag(_:)-(HTMLElement)`` where a case exists for the
    /// element. Names given here are validated when the document is emitted;
    /// an invalid name is dropped rather than written into the output.
    ///
    /// - Parameter name: The element name, e.g. `"hgroup"`.
    /// - Returns: The view, tagged with the requested element.
    public func htmlTag(_ name: String) -> some View {
        htmlTag(.custom(name))
    }

    /// Adds HTML attributes to this view's element.
    ///
    /// Every attribute is writable, including `class`, `style`, and the
    /// `data-scui` namespace — see the caveats on each below. The operation
    /// an author reaches for follows the attribute's own grammar; see
    /// ``HTMLAttributeOp``. A plain string, e.g. `["aria-label": "Primary"]`,
    /// is shorthand for `.set(_:)` and works for any scalar attribute.
    /// Values are escaped when emitted.
    ///
    /// A block naming an `id` lands on the modified view's own element, which
    /// emits even if it would otherwise be dropped as an empty wrapper — a
    /// referenced identity has to sit where the author put it. A block naming
    /// no `id` describes whatever element ends up carrying the content, so it
    /// rides through wrappers that emit nothing and lands on the first
    /// element that survives.
    ///
    /// `class` is token-list: `.add(_:)`/`.remove(_:)`/`.replace(_:with:)`
    /// operate on the element's class list the way `classList` does,
    /// including the class the backend interned for this element's own
    /// styling — `.add(_:)` appends an author token after it, and
    /// `.remove(_:)`/`.replace(_:with:)` reach it too, deliberately: a
    /// backend-owned token isn't exempt from an explicit author op. `.set(_:)`
    /// replaces the class list wholesale, backend token included.
    ///
    /// `style` is scalar or property-map, author-owned either way. This
    /// backend never writes `style` itself — its own styling always goes
    /// through interned classes — so an author's `style` ops are the only
    /// source of an inline `style` attribute (same precedent as
    /// `HTMLRawFragment`'s raw markup). `.setProperty(_:value:)` and
    /// `.removeProperty(_:)` merge per CSS declaration; `.set(_:)` replaces
    /// the whole attribute with a raw string. **Caveat:** values set this way
    /// bypass the backend's color-scheme swap and any tier-level CSS choice
    /// for the same property — an inline `color` won't follow the reader's
    /// system appearance the way the backend's own styling does.
    ///
    /// `data-scui-*` is the backend's build↔runtime protocol namespace —
    /// **private API**. It's writable with no precondition or ceremony
    /// (e.g. a user-space component steering another component's behavior
    /// through the same channel the backend uses), but nothing about it is
    /// contractually stable: names, values, and presence can change without
    /// notice as the backend's own emission logic evolves.
    ///
    /// Every other attribute is scalar: an author's `.set(_:)`/string
    /// literal always wins the final value once merged, but a
    /// backend-derived value applied after author-attribute merging (e.g.
    /// `id` from a referenced identifier, `aria-labelledby` from a label
    /// association) still overwrites it — see the emission order in
    /// `HTMLEmitter`.
    ///
    /// Stacking this modifier is legal and merges: `.htmlAttributes(["a":
    /// "1"]).htmlAttributes(["b": "2"])` resolves to both `a` and `b` on the
    /// element. On a key both calls set, the one closer to the content — the
    /// later, "more inside" call in the chain — wins, mirroring how nested
    /// environment overrides work generally. This is unlike ``htmlTag(_:)``
    /// or ``href(_:)``, which are single-valued and where a later call
    /// simply replaces the earlier one.
    ///
    /// - Parameter attributes: The attribute operations to apply, keyed by
    ///   name.
    /// - Returns: The view, carrying the requested attributes.
    public func htmlAttributes(_ attributes: [String: HTMLAttributeOp]) -> some View {
        let block = HTMLAttributeBlock(attributes: attributes)
        return transformEnvironment(\.htmlIdentifiedAttributes) { identified in
            if block.materializes {
                identified.append(block)
            }
        }
        .transformEnvironment(\.htmlAttributes) { unidentified in
            guard !block.materializes else {
                return
            }
            unidentified = unidentified?.layering(block) ?? block
        }
    }

    /// Gives this view's subtree navigation intent, so every href-capable
    /// view within it resolves to a real, live `<a href>` under
    /// StaticHTMLBackend rather than a disabled control waiting on a runtime.
    ///
    /// Per the tier-activation principle: an `href` is fully resolvable in
    /// pure HTML — the browser handles navigation on its own — so a `Button`,
    /// ``SwiftCrossUI/NavigationLink``, or similar view carrying one is live
    /// at the static tier and needs no script to become usable. A view with
    /// no `.href(_:)` but a click action, by contrast, has nothing pure HTML
    /// can resolve — it emits `disabled` until a later tier attaches the
    /// handler.
    ///
    /// The destination flows down the subtree and is consumed by the
    /// href-capable views it reaches, however many there are: applying it to
    /// a container of links sends all of them to the same place. A container
    /// never becomes a link itself — an element that merely holds links is
    /// not a link — and a consumer clears the destination from its own
    /// children, so a link's label doesn't inherit its link's destination. A
    /// nearer application overrides a farther one for the views it covers,
    /// leaving that view's siblings on the outer destination.
    ///
    /// An `.href(_:)` that reaches no consumer at all emits nothing and is
    /// reported through ``DocumentInfo/hrefsWithoutConsumer``, rather than
    /// silently disappearing.
    ///
    /// A view can carry both a click action and `.href(_:)` at once (a
    /// `Button` that both navigates and runs code, e.g. an analytics-tracked
    /// link). That's legal: the emitted element is still the live `<a href>`
    /// — the link half is what pure HTML can resolve — but it also carries
    /// the enliven marker so a later tier can attach the action. See the
    /// `href+action` row in ``HTMLEmitter``'s button case for the exact
    /// markup and the modified-click contract that binds the code which
    /// attaches that handler.
    ///
    /// This modifier only affects StaticHTMLBackend. Under any other backend
    /// it does nothing, so a view hierarchy carrying it stays portable.
    ///
    /// - Parameter href: The URL or path to navigate to.
    /// - Returns: The view, carrying the requested navigation intent.
    public func href(_ href: String) -> some View {
        environment(\.htmlHref, href)
    }
}
