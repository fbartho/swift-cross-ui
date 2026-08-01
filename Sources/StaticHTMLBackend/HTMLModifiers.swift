import SwiftCrossUI

/// A request to emit one view as a specific element.
///
/// The environment propagates to every descendant, but an element name must
/// apply to exactly one element. Identity is what distinguishes one request
/// from another, so this is a reference type: the renderer gives the request
/// to the topmost widget that saw it, which is the modified view itself.
public final class HTMLTagRequest: Sendable {
    /// The requested element.
    public let element: HTMLElement

    /// Creates a request.
    ///
    /// - Parameter element: The element to emit.
    public init(element: HTMLElement) {
        self.element = element
    }
}

/// A request to add attributes to one view's element.
///
/// Resolved by identity, for the same reason as ``HTMLTagRequest``.
public final class HTMLAttributesRequest: Sendable {
    /// The requested attributes.
    public let attributes: [String: String]

    /// Creates a request.
    ///
    /// - Parameter attributes: The attributes to add.
    public init(attributes: [String: String]) {
        self.attributes = attributes
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
        environment(\.htmlTagRequest, HTMLTagRequest(element: element))
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
        environment(\.htmlTagRequest, HTMLTagRequest(element: .custom(name)))
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
        environment(\.htmlAttributesRequest, HTMLAttributesRequest(attributes: attributes))
    }
}
