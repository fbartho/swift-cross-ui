import SwiftCrossUI

/// A view that writes an HTML comment into the document.
///
/// Emitted as `<!-- The comment -->` at the same indentation as the siblings
/// around it, for annotating generated markup — a section boundary, a
/// generator's provenance note, an instruction to whoever reads the output.
///
/// ```swift
/// VStack {
///     HTMLComment("Navigation starts here")
///     NavigationBar()
/// }
/// ```
///
/// ## Sanitization
///
/// A payload containing `-->` would end the comment early and spill the rest
/// into the document as markup, so the terminator is defanged rather than
/// passed through: see ``HTMLComment/sanitize(_:)`` for the exact
/// transformation and what it deliberately leaves alone.
///
/// The payload is code-authored — a `precondition` on the terminator would be
/// defensible — but a transformation that can't break the document is
/// friendlier than a crash, and the escaped form still shows the author what
/// they wrote.
///
/// ## What it costs
///
/// The comment rides ``RawHTMLFragment``'s infrastructure: a zero-size leaf
/// that the emitter replaces outright, with a `display:contents` wrapper chain
/// so it never participates in layout. Comments aren't boxes, and siblings lay
/// out as though it weren't there.
///
/// Under any other backend this renders nothing at all, which is the intended
/// behaviour — a comment has no native equivalent.
public struct HTMLComment: View {
    /// The comment's text, before sanitization.
    public var text: String

    /// Creates a comment.
    ///
    /// - Parameter text: The text to write between the comment delimiters.
    ///   Comment-terminating sequences are neutralized; see
    ///   ``HTMLComment/sanitize(_:)``.
    public init(_ text: String) {
        self.text = text
    }

    /// Neutralizes the sequences that would end a comment early.
    ///
    /// Two transformations, both minimal:
    ///
    /// - `-->` becomes `--&gt;`. This is the only sequence a browser actually
    ///   ends a comment on, and replacing the `>` keeps the author's text
    ///   legible in the output while leaving the parser nothing to match.
    ///   Entities aren't decoded inside comments, so the `&gt;` is literal
    ///   text rather than a hidden `>`.
    /// - A trailing `-` gets a space appended, since `--->` would otherwise
    ///   reintroduce a terminator when the closing delimiter is appended.
    ///
    /// A bare `--` is left alone. The HTML spec disallows it inside a comment
    /// (and also forbids text starting with `>` or `->`), but no browser
    /// treats it as a terminator, and rewriting every double hyphen would
    /// corrupt ordinary prose — an em-dash written as `--`, a CLI flag like
    /// `--verbose`. Validators may flag it; the document still parses as
    /// intended, which is the tradeoff this picks deliberately.
    ///
    /// - Parameter text: The author's comment text.
    /// - Returns: Text that cannot terminate the comment early.
    public static func sanitize(_ text: String) -> String {
        var sanitized = text.replacingOccurrences(of: "-->", with: "--&gt;")
        if sanitized.hasSuffix("-") {
            sanitized += " "
        }
        return sanitized
    }

    public var body: some View {
        // The payload rides the environment down to a zero-size leaf, the
        // same path RawHTMLFragment uses. Set here rather than by nesting a
        // RawHTMLFragment, which would add another wrapper level between this
        // view and the leaf and indent the spliced comment one step further
        // from the siblings it annotates.
        SwiftCrossUI.Color.clear
            .frame(width: 0, height: 0)
            .transformEnvironment(\.htmlRawFragmentRequest) { request in
                request = HTMLRawFragmentRequest(
                    html: "<!-- \(Self.sanitize(text)) -->",
                    enclosing: request
                )
            }
    }
}
