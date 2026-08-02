import SwiftCrossUI

/// A request to splice markup into the document in place of a view.
///
/// Resolved by identity, the same as ``HTMLTagRequest`` — see that type for why
/// these are reference types.
public final class HTMLRawFragmentRequest: Sendable {
    /// The markup to splice, verbatim.
    public let html: String
    /// The name of the slot whose items should be spliced instead, if this
    /// request came from a ``SlotComponent`` rather than a
    /// ``RawHTMLFragment``.
    public let slotName: String?
    /// The request this one shadowed, if it was applied inside another.
    public let enclosing: HTMLRawFragmentRequest?

    /// Creates a request.
    ///
    /// - Parameters:
    ///   - html: The markup to splice.
    ///   - slotName: The slot to splice, for a slot marker.
    ///   - enclosing: The request already in scope, which this one shadows.
    public init(
        html: String,
        slotName: String? = nil,
        enclosing: HTMLRawFragmentRequest? = nil
    ) {
        self.html = html
        self.slotName = slotName
        self.enclosing = enclosing
    }
}

extension EnvironmentValues {
    /// Markup to splice in place of a view, from ``RawHTMLFragment``.
    ///
    /// Only consumed by StaticHTMLBackend; other backends never read it, which
    /// is what makes a ``RawHTMLFragment`` render as nothing under them.
    @Entry public var htmlRawFragmentRequest: HTMLRawFragmentRequest?
}

/// A view whose payload is written into the document verbatim.
///
/// The escape hatch for markup this backend has no view vocabulary for — an
/// embedded `<iframe>`, a third-party widget's snippet, a block of markdown
/// that was already rendered to HTML upstream.
///
/// ## Security stance
///
/// **The payload is not escaped, sanitized, or validated.** Whatever is passed
/// here reaches the document unchanged, so passing untrusted input — anything
/// derived from user data, a form submission, a remote API — is an XSS
/// vulnerability. This is the only unescaped sink in a backend that otherwise
/// escapes every string it emits, and it's caller-trusted by design: sanitizing
/// would require a policy this backend has no business choosing. Escape or
/// sanitize before the string gets here.
///
/// ## What it costs
///
/// The fragment is opaque to everything the backend derives from the tree. It
/// contributes no headings to the document outline, no accessibility
/// information, and it has no size on the build host — a zero-size hole in
/// layout. The emitter compensates for this in flow: every wrapper on the
/// way to the fragment's leaf emits `display:contents` rather than trusting
/// its own honestly-computed 0x0 as a real box, so the browser sizes the
/// real content when it parses it and the fragment becomes a genuine
/// participant in whatever flex arrangement it sits inside, instead of a
/// zero-size flex item that lets its content spill over a sibling. Inside an
/// absolutely-positioned subtree it is still a lie, and surrounding geometry
/// will be computed as though the fragment weren't there.
///
/// Under any other backend this renders nothing at all, so a cross-platform
/// tree using one needs an author-provided native alternative alongside it.
public struct RawHTMLFragment: View {
    /// The markup to splice.
    public var html: String

    /// Creates a fragment.
    ///
    /// - Parameter html: The markup to write into the document verbatim. See
    ///   the type's security stance: this is never escaped.
    public init(_ html: String) {
        self.html = html
    }

    /// Creates a fragment from a string builder.
    ///
    /// - Parameter html: A closure returning the markup to splice.
    public init(@_implicitSelfCapture html: () -> String) {
        self.init(html())
    }

    public var body: some View {
        // The payload rides the environment down to the one widget this view
        // produces, which is the same path .htmlTag() uses to get an element
        // name to a widget without the backend protocol knowing about it. The
        // marker below is what the emitter matches on.
        SwiftCrossUI.Color.clear
            .frame(width: 0, height: 0)
            .transformEnvironment(\.htmlRawFragmentRequest) { request in
                request = HTMLRawFragmentRequest(html: html, enclosing: request)
            }
    }
}

/// A marker view that a document's custom slot is emitted at.
///
/// Custom slots are introduced by placing this in the tree rather than by
/// naming a position relative to head or body. A tree-resident marker keeps its
/// place in the document as the tree changes, and it gives a future runtime
/// tier something to find and re-evaluate when a slot's contents change — a
/// head/tail-relative offset would have neither property.
///
/// The named slot must be declared on the ``DocumentContext``; a marker for an
/// undeclared name is a typo and fails the render rather than emitting an empty
/// hole.
public struct SlotComponent: View {
    /// The name of the slot to emit here.
    public var name: String

    /// Creates a slot marker.
    ///
    /// - Parameter name: The slot's name, which must be declared on the
    ///   document context.
    public init(_ name: String) {
        self.name = name
    }

    public var body: some View {
        SwiftCrossUI.Color.clear
            .frame(width: 0, height: 0)
            .transformEnvironment(\.htmlRawFragmentRequest) { request in
                request = HTMLRawFragmentRequest(
                    html: "",
                    slotName: name,
                    enclosing: request
                )
            }
    }
}
