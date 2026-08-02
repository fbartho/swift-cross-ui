import SwiftCrossUI

/// A request to emit one view as a specific element.
///
/// The environment propagates to every descendant, but an element name must
/// apply to exactly one element. Identity is what distinguishes one request
/// from another, so this is a reference type: the renderer gives the request
/// to the topmost widget that saw it, which is the modified view itself.
///
/// A request nested inside another keeps a reference to the one it shadowed.
/// The environment only ever holds the innermost request, so without that link
/// a widget under `.htmlTag(.header)` whose sibling subtree overrode the tag
/// would leave the outer request with no widget reporting it, and the header
/// would be lost or scattered across the leaves that didn't override.
///
/// **Single-valued, so innermost-wins-outright is correct here.** An element
/// has exactly one tag; two stacked `.htmlTag(_:)` calls are a genuine
/// override, not two facts that both deserve to reach the document, so the
/// outer one is meant to be fully shadowed. Contrast ``HTMLAttributesRequest``,
/// which is dictionary-valued — many attributes can coexist on one element —
/// and merges its stacked requests instead of discarding the outer one.
public final class HTMLTagRequest: Sendable {
    /// The requested element.
    public let element: HTMLElement
    /// The request this one shadowed, if it was applied inside another.
    public let enclosing: HTMLTagRequest?

    /// Creates a request.
    ///
    /// - Parameters:
    ///   - element: The element to emit.
    ///   - enclosing: The request already in scope, which this one shadows.
    public init(element: HTMLElement, enclosing: HTMLTagRequest? = nil) {
        self.element = element
        self.enclosing = enclosing
    }
}

/// A request to add attributes to one view's element.
///
/// Resolved by identity, for the same reason as ``HTMLTagRequest`` — but
/// unlike a tag or an `href`, an element can carry any number of attributes
/// at once, so a request here doesn't *shadow* the one it encloses the way
/// ``HTMLTagRequest``/``HTMLHrefRequest`` do. It's kept alongside it: when
/// several `.htmlAttributes(_:)` calls stack on one view, every one of them
/// resolves onto the same element, merged key-by-key with the innermost
/// (closest to the content) winning a conflict — the same "most specific
/// wins" intuition as CSS cascade or nested environment overrides. See
/// `StaticHTMLRenderer.mergedAttributes(from:)`, which walks `enclosing` to
/// perform that merge; the field exists on this type only to make the chain
/// walkable, not because outer requests are meant to be discarded.
public final class HTMLAttributesRequest: Sendable {
    /// The requested attributes.
    public let attributes: [String: String]
    /// The request this one was applied inside, if any — see the type's doc
    /// comment: this is *not* a shadowed-and-discarded predecessor the way
    /// it is for ``HTMLTagRequest``, it's the next entry a merge walks to.
    public let enclosing: HTMLAttributesRequest?

    /// Creates a request.
    ///
    /// - Parameters:
    ///   - attributes: The attributes to add.
    ///   - enclosing: The request already in scope, which this one is
    ///     layered onto (not shadowing — see the type's doc comment).
    public init(attributes: [String: String], enclosing: HTMLAttributesRequest? = nil) {
        self.attributes = attributes
        self.enclosing = enclosing
    }
}

/// A request to give one view's element a navigation-intent `href`.
///
/// Kept distinct from ``HTMLAttributesRequest`` — rather than folding this
/// into a generic `"href"` key — because the emitter has to tell "the author
/// declared navigation intent" apart from "the author attached an arbitrary
/// attribute that happens to be named href": the former is the signal that
/// picks a row out of the Button/NavigationLink emission matrix (see
/// ``HTMLEmitter``'s button case), the latter is inert data with no bearing
/// on which element or activation state gets emitted.
///
/// **Single-valued, so innermost-wins-outright is correct here**, the same
/// reasoning as ``HTMLTagRequest``: an element navigates to one place, so a
/// second `.href(_:)` is an override, not an addition — see that type's doc
/// comment for the contrast with ``HTMLAttributesRequest``'s merge behavior.
public final class HTMLHrefRequest: Sendable {
    /// The requested href value.
    public let href: String
    /// The request this one shadowed, if it was applied inside another.
    public let enclosing: HTMLHrefRequest?

    /// Creates a request.
    ///
    /// - Parameters:
    ///   - href: The href to give the view's element.
    ///   - enclosing: The request already in scope, which this one shadows.
    public init(href: String, enclosing: HTMLHrefRequest? = nil) {
        self.href = href
        self.enclosing = enclosing
    }
}

extension EnvironmentValues {
    /// An explicit element requested by ``View/htmlTag(_:)``.
    ///
    /// Only consumed by StaticHTMLBackend; other backends never read it.
    @Entry public var htmlTagRequest: HTMLTagRequest?

    /// Extra attributes requested by ``View/htmlAttributes(_:)``.
    @Entry public var htmlAttributesRequest: HTMLAttributesRequest?

    /// Navigation-intent href requested by ``View/href(_:)``.
    @Entry public var htmlHrefRequest: HTMLHrefRequest?
}

extension View {
    /// Emits this view using a specific HTML element.
    ///
    /// Use this when a view's role in the document isn't something the backend
    /// can derive. Deriving semantics from layout or styling would be
    /// guesswork, so anything the backend isn't told about becomes a `div`.
    ///
    /// This modifier only affects StaticHTMLBackend. Under any other backend
    /// it does nothing, so a view hierarchy carrying it stays portable.
    ///
    /// - Parameter element: The element to emit the view as.
    /// - Returns: The view, tagged with the requested element.
    public func htmlTag(_ element: HTMLElement) -> some View {
        transformEnvironment(\.htmlTagRequest) { request in
            request = HTMLTagRequest(element: element, enclosing: request)
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
        transformEnvironment(\.htmlTagRequest) { request in
            request = HTMLTagRequest(element: .custom(name), enclosing: request)
        }
    }

    /// Adds HTML attributes to this view's element.
    ///
    /// Author attributes win over backend-derived ones, except for `style`,
    /// `class`, and `data-scui`, which the backend owns — style interning and
    /// the type-name attribute would both break if authors could overwrite
    /// them. Values are escaped when emitted.
    ///
    /// Stacking this modifier is legal and merges: `.htmlAttributes(["a":
    /// "1"]).htmlAttributes(["b": "2"])` resolves to both `a` and `b` on the
    /// element. On a key both calls set, the one closer to the content — the
    /// later, "more inside" call in the chain — wins, mirroring how nested
    /// environment overrides work generally. This is unlike ``htmlTag(_:)``
    /// or ``href(_:)``, which are single-valued and where a later call
    /// simply replaces the earlier one; see ``HTMLAttributesRequest``'s doc
    /// comment for why attributes are the case that merges.
    ///
    /// - Parameter attributes: The attributes to add, keyed by name.
    /// - Returns: The view, carrying the requested attributes.
    public func htmlAttributes(_ attributes: [String: String]) -> some View {
        transformEnvironment(\.htmlAttributesRequest) { request in
            request = HTMLAttributesRequest(attributes: attributes, enclosing: request)
        }
    }

    /// Gives this view navigation intent, so its element resolves to a real,
    /// live `<a href>` under StaticHTMLBackend rather than a disabled control
    /// waiting on a runtime.
    ///
    /// Per the tier-activation principle: an `href` is fully resolvable in
    /// pure HTML — the browser handles navigation on its own — so a `Button`,
    /// ``SwiftCrossUI/NavigationLink``, or similar view carrying one is live
    /// at the static tier and needs no script to become usable. A view with
    /// no `.href(_:)` but a click action, by contrast, has nothing pure HTML
    /// can resolve — it emits `disabled` until a later tier attaches the
    /// handler.
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
        transformEnvironment(\.htmlHrefRequest) { request in
            request = HTMLHrefRequest(href: href, enclosing: request)
        }
    }
}
