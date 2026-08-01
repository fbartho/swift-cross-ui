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
/// Resolved by identity, for the same reason as ``HTMLTagRequest``.
public final class HTMLAttributesRequest: Sendable {
    /// The requested attributes.
    public let attributes: [String: String]
    /// The request this one shadowed, if it was applied inside another.
    public let enclosing: HTMLAttributesRequest?

    /// Creates a request.
    ///
    /// - Parameters:
    ///   - attributes: The attributes to add.
    ///   - enclosing: The request already in scope, which this one shadows.
    public init(attributes: [String: String], enclosing: HTMLAttributesRequest? = nil) {
        self.attributes = attributes
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
    /// - Parameter attributes: The attributes to add, keyed by name.
    /// - Returns: The view, carrying the requested attributes.
    public func htmlAttributes(_ attributes: [String: String]) -> some View {
        transformEnvironment(\.htmlAttributesRequest) { request in
            request = HTMLAttributesRequest(attributes: attributes, enclosing: request)
        }
    }
}
