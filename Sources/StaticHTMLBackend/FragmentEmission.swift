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
    ///
    /// Every selector must keep its `#root` prefix *inside* `:where()`, which
    /// zeroes the block's specificity. Left bare, `#root` scores (1,0,0) and
    /// outranks the interned classes (0,1,0) carrying each view's declared
    /// style, so the reset would win and headings would render flat.
    ///
    /// Buttons and links carry a default appearance rather than only being
    /// neutralized. Flattening a control's user-agent styling without
    /// replacing it leaves it indistinguishable from surrounding text, and a
    /// native backend's button gets its look from the platform widget
    /// (`NSButton`, `GtkButton`) with nothing declared in Swift — so the
    /// equivalent has to come from here. The appearance is this backend's
    /// own, not a return to user-agent defaults, which differ per browser
    /// and would make output inconsistent across them.
    ///
    /// Colors use `light-dark()`, which is live because `color-scheme` is
    /// declared above. Unlike the palette's custom properties, these aren't
    /// author colors reaching the emitter through a render — they're the
    /// backend's own chrome, so they need no per-page plumbing.
    static func resetItem() -> FragmentItem {
        FragmentItem(
            key: .reset,
            slot: .head,
            content: .style(
                """
                :root { color-scheme: light dark; }
                body { margin: 0; font-family: -apple-system, system-ui, sans-serif; }
                :where(#root h1, #root h2, #root h3, #root h4, #root h5, #root h6, #root p) {
                  margin: 0;
                  font-size: inherit;
                  font-weight: inherit;
                }
                :where(#root a) { color: inherit; }
                :where(#root a[href]) {
                  text-decoration: underline;
                  text-underline-offset: 0.15em;
                  text-decoration-thickness: from-font;
                }
                :where(#root a[href]:hover, #root a[href]:focus-visible) {
                  text-decoration-thickness: 0.12em;
                }
                :where(#root button, #root input) {
                  margin: 0;
                  padding: 0;
                  border: none;
                  background: none;
                  font: inherit;
                  color: inherit;
                  appearance: none;
                }
                :where(#root button) {
                  padding: 0.3em 0.8em;
                  border: 1px solid light-dark(rgba(0,0,0,0.28), rgba(255,255,255,0.32));
                  border-radius: 0.4em;
                  background: light-dark(rgba(255,255,255,0.9), rgba(255,255,255,0.09));
                  cursor: pointer;
                }
                :where(#root button:hover:not(:disabled)) {
                  background: light-dark(rgba(0,0,0,0.05), rgba(255,255,255,0.16));
                }
                :where(#root button:disabled, #root input:disabled, #root a:not([href])) {
                  opacity: 0.55;
                  cursor: default;
                }
                """
            )
        )
    }
}
