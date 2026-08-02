import Foundation

extension FragmentItem {
    /// The item rendered as markup.
    ///
    /// Every emitted item carries `data-scui-head-id`, which is what makes
    /// registration idempotent across the build-time/runtime boundary: a
    /// runtime tier looks for the marker before injecting the same item, so an
    /// asset the static build already emitted is never injected twice. See
    /// ``HTMLFragmentRegistry``.
    ///
    /// - Parameter indent: The indentation to write the markup at.
    /// - Returns: The item's markup.
    func rendered(indent: String) -> String {
        let marker = " data-scui-head-id=\"\(HTMLEmitter.escape(key.markerValue))\""

        switch content {
            case .script(let src, let attributes):
                let extra = Self.renderAttributes(attributes)
                return "\(indent)<script src=\"\(HTMLEmitter.escape(src))\"\(extra)\(marker)></script>"

            case .inlineScript(let source):
                // Script and style bodies are CDATA-ish: HTML entities aren't
                // decoded inside them, so escaping the body would corrupt the
                // code rather than protect anything. The one sequence that can
                // break out is a literal `</script`, which is neutralized
                // below without touching anything else.
                return """
                    \(indent)<script\(marker)>
                    \(Self.escapeScriptBody(source))
                    \(indent)</script>
                    """

            case .stylesheet(let href):
                return
                    "\(indent)<link rel=\"stylesheet\" href=\"\(HTMLEmitter.escape(href))\"\(marker)>"

            case .style(let css):
                return """
                    \(indent)<style\(marker)>
                    \(Self.escapeStyleBody(css))
                    \(indent)</style>
                    """

            case .meta(let attributes):
                return "\(indent)<meta\(Self.renderAttributes(attributes))\(marker)>"

            case .rawHTML(let html):
                // Unescaped by contract — the same caller-trusted stance as
                // RawHTMLFragment. A wrapper element would be the only place to
                // hang the marker, and wrapping arbitrary markup changes what
                // it means (a <div> around a <tr>, say), so raw items forgo the
                // cross-tier marker rather than distort their payload.
                return "\(indent)\(html)"
        }
    }

    /// Renders an attribute dictionary, sorted for deterministic output.
    private static func renderAttributes(_ attributes: [String: String]) -> String {
        attributes
            .sorted { $0.key < $1.key }
            .filter { HTMLElement.isValidName($0.key) }
            .map { name, value in " \(name)=\"\(HTMLEmitter.escape(value))\"" }
            .joined()
    }

    /// Neutralizes the one sequence that can terminate a script element early.
    ///
    /// The HTML parser ends a script at the first `</script`, wherever it
    /// appears — inside a string literal included. Splitting the tag across a
    /// string concatenation keeps the JavaScript equivalent while giving the
    /// parser nothing to match.
    private static func escapeScriptBody(_ source: String) -> String {
        source.replacingOccurrences(
            of: "</script",
            with: "<\\/script",
            options: .caseInsensitive
        )
    }

    /// Neutralizes the sequence that can terminate a style element early.
    private static func escapeStyleBody(_ css: String) -> String {
        css.replacingOccurrences(
            of: "</style",
            with: "<\\/style",
            options: .caseInsensitive
        )
    }
}

extension HTMLFragmentRegistry {
    /// The emitter's own baseline stylesheet, as a registrable item.
    ///
    /// Registered under ``FragmentItem/DedupeKey/reset`` so that a page owner
    /// who registers their own item under that key replaces it outright.
    /// Because the registry keeps the *first* item per key and the emitter adds
    /// this one last, an override needs no special casing — it simply got there
    /// first.
    ///
    /// The reset is deliberately not a reset *library*. This backend's output
    /// leans on user-agent defaults it would be wrong to flatten (list markers,
    /// blockquote indentation); what needs neutralizing is only the small set
    /// of defaults that fight values the layout system already resolved.
    static func resetItem() -> FragmentItem {
        FragmentItem(
            key: .reset,
            slot: .head,
            content: .style(
                """
                :root { color-scheme: light dark; }
                body { margin: 0; font-family: -apple-system, system-ui, sans-serif; }
                /* Font sizing and weight come from the declared text styles the
                   layout system resolved, so the user agent's heading defaults
                   would only fight them. Margins likewise: spacing between
                   elements is the stacks' gap, not the browser's.

                   The whole selector is wrapped in :where(), not just the tag
                   list, so the block carries zero specificity. #root on its own
                   is an id selector — (1,0,0) — which would otherwise outrank
                   every interned class (0,1,0) and make a heading's declared
                   font-size lose to this reset instead of the other way around. */
                :where(#root h1, #root h2, #root h3, #root h4, #root h5, #root h6, #root p) {
                  margin: 0;
                  font-size: inherit;
                  font-weight: inherit;
                }
                :where(#root a) { color: inherit; }
                /* The tier-activation principle (task #29) means Button now emits
                   a real button element for its floor-disabled, action-only row,
                   rather than the link-with-a-button-role this backend used to
                   fall back to. A real button drags in UA chrome (its own font,
                   border, background, padding) that the interned class for its
                   declared style has to fight otherwise. Kept minimal and
                   specifically scoped to button/input, the same low-specificity
                   :where() shape as the rest of this reset, so it doesn't need
                   to win a specificity fight against anything: appearance:none
                   only strips the platform's own decoration, everything else
                   (color, spacing, sizing) is still this backend's interned
                   class to set. */
                :where(#root button, #root input) {
                  margin: 0;
                  padding: 0;
                  border: none;
                  background: none;
                  font: inherit;
                  color: inherit;
                  appearance: none;
                }
                """
            )
        )
    }
}
