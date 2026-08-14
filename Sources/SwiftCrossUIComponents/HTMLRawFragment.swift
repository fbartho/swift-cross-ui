import SwiftCrossUI

/// A request to splice markup into the document in place of a view.
///
/// Resolved by identity, and a reference type for that reason. The request is
/// in scope for exactly one zero-size leaf of the view's own making, so the
/// leaf reporting it *is* the view the author wrote.
public final class HTMLRawFragmentRequest: Sendable {
    /// The markup to splice, verbatim.
    public let html: String
    /// The name of the slot whose items should be spliced instead, if this
    /// request came from a ``HTMLSlot`` rather than a
    /// ``HTMLRawFragment``.
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
    /// Markup to splice in place of a view, from ``HTMLRawFragment``.
    ///
    /// Only consumed by StaticHTMLBackend; other backends never read it, which
    /// is what makes a ``HTMLRawFragment`` render as nothing under them.
    @Entry public var htmlRawFragmentRequest: HTMLRawFragmentRequest?
}

/// How a ``HTMLRawFragment`` renders under a backend other than
/// StaticHTMLBackend.
///
/// A non-web backend has no way to execute the markup a fragment carries, so
/// there's nothing to render it *as* — this only chooses whether the source
/// itself is visible, for the sake of noticing a fragment is there while
/// building or debugging a cross-platform tree.
public enum RawFragmentNativeDisplay: Hashable, Sendable {
    /// The fragment's markup, shown verbatim as preformatted monospaced text.
    case source
    /// The fragment renders as nothing, taking no space.
    case hidden
}

extension EnvironmentValues {
    /// How a ``HTMLRawFragment`` displays under a non-web backend.
    ///
    /// Set at the app root with `.environment(\.rawFragmentNativeDisplay,
    /// .hidden)` to flip every fragment in the tree at once. A fragment's own
    /// `nativeDisplay` constructor parameter, when non-`nil`, overrides this
    /// for that one instance.
    ///
    /// StaticHTMLBackend never consults this value — the web path always
    /// splices the fragment's markup regardless of what's set here.
    @Entry public var rawFragmentNativeDisplay: RawFragmentNativeDisplay = .source
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
/// Under any other backend this renders its source as preformatted text by
/// default — see ``SwiftCrossUI/EnvironmentValues/rawFragmentNativeDisplay``
/// to hide it instead, either app-wide or per instance.
public struct HTMLRawFragment: View {
    @Environment(\.rawFragmentNativeDisplay) var environmentNativeDisplay

    /// The markup to splice.
    public var html: String

    /// Overrides ``SwiftCrossUI/EnvironmentValues/rawFragmentNativeDisplay``
    /// for this instance. `nil` (the default) follows the environment.
    public var nativeDisplay: RawFragmentNativeDisplay?

    /// Creates a fragment.
    ///
    /// - Parameters:
    ///   - html: The markup to write into the document verbatim. See the
    ///     type's security stance: this is never escaped.
    ///   - nativeDisplay: Overrides how this instance displays under a
    ///     non-web backend. `nil` follows
    ///     ``SwiftCrossUI/EnvironmentValues/rawFragmentNativeDisplay``.
    public init(_ html: String, nativeDisplay: RawFragmentNativeDisplay? = nil) {
        self.html = html
        self.nativeDisplay = nativeDisplay
    }

    /// Creates a fragment from a string builder.
    ///
    /// - Parameters:
    ///   - nativeDisplay: Overrides how this instance displays under a
    ///     non-web backend. `nil` follows
    ///     ``SwiftCrossUI/EnvironmentValues/rawFragmentNativeDisplay``.
    ///   - html: A closure returning the markup to splice.
    public init(
        nativeDisplay: RawFragmentNativeDisplay? = nil,
        @_implicitSelfCapture html: () -> String
    ) {
        self.init(html(), nativeDisplay: nativeDisplay)
    }

    public var body: some View {
        // The payload rides the environment down to the one widget each
        // branch produces, which is the same path .htmlTag() uses to get an
        // element name to a widget without the backend protocol knowing
        // about it. StaticHTMLBackend's emitter matches on this and replaces
        // that widget entirely, so what a branch renders is irrelevant to
        // the web path — only a non-web backend, which never reads this
        // environment value, ever shows it. Both branches apply the
        // transform themselves, rather than sharing one application over a
        // switch, so each keeps producing a single childless widget for the
        // emitter to find; a shared wrapper would interpose a container.
        switch nativeDisplay ?? environmentNativeDisplay {
            case .source:
                Text(html)
                    .font(.system(size: 13).monospaced())
                    .transformEnvironment(\.htmlRawFragmentRequest) { request in
                        request = HTMLRawFragmentRequest(html: html, enclosing: request)
                    }
            case .hidden:
                // Color.clear rather than EmptyView: only a widget that sets
                // a color captures the pending raw-fragment request on
                // StaticHTMLBackend (see StaticHTMLBackend.setColor),
                // and this leaf has to carry that request regardless of
                // which native display mode is in effect — the web path
                // never consults nativeDisplay, so both branches must stay
                // spliceable.
                SwiftCrossUI.Color.clear
                    .frame(width: 0, height: 0)
                    .transformEnvironment(\.htmlRawFragmentRequest) { request in
                        request = HTMLRawFragmentRequest(html: html, enclosing: request)
                    }
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
public struct HTMLSlot: View {
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
