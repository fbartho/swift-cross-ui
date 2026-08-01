import Foundation
@_spi(Backends) import SwiftCrossUI

/// Renders a view tree to a standalone HTML document.
///
/// The view is laid out twice, once per color scheme. Layout is expected to be
/// identical between the two passes — color scheme shouldn't reach the layout
/// system — so the second pass exists only to learn each color's dark-mode
/// value. Where the two passes disagree on geometry, the light pass wins and
/// the disagreement is reported in ``RenderResult/geometryMismatches``.
@MainActor
public enum StaticHTMLRenderer {
    /// The result of rendering a view.
    public struct RenderResult {
        /// The complete HTML document.
        public var html: String
        /// The root view's committed size.
        public var size: SIMD2<Int>
        /// Widgets whose geometry differed between the two color scheme
        /// passes.
        ///
        /// Expected to be empty. A non-empty result means some view is
        /// branching its layout on the color scheme, which makes a single
        /// static document unable to describe both appearances.
        public var geometryMismatches: [GeometryMismatch]
    }

    /// A geometry difference observed between the two color scheme passes.
    public struct GeometryMismatch: Hashable, Sendable {
        /// The view type name of the widget that differed.
        public var tag: String
        /// The widget's size in the light pass.
        public var lightSize: SIMD2<Int>
        /// The widget's size in the dark pass.
        public var darkSize: SIMD2<Int>
    }

    /// Renders a view to a complete HTML document.
    ///
    /// - Parameters:
    ///   - view: The view to render.
    ///   - title: The document's title.
    ///   - size: The size to lay the view out against. Only the width is a
    ///     constraint; see the note on height in ``layOut(_:size:colorScheme:)``.
    ///   - headingMap: The mapping used to derive headings from declared text
    ///     styles.
    /// - Returns: The rendered document along with anything notable observed
    ///   while producing it.
    public static func render(
        _ view: some View,
        title: String,
        size: SIMD2<Int> = SIMD2(800, 600),
        headingMap: HeadingMap = .default
    ) -> RenderResult {
        let light = layOut(view, size: size, colorScheme: .light)
        let dark = layOut(view, size: size, colorScheme: .dark)

        let mismatches = geometryMismatches(between: light.widget, and: dark.widget)
        mergeColors(from: dark.widget, into: light.widget)
        resolveIntent(in: light.widget)

        var emitter = HTMLEmitter(headingMap: headingMap)
        let body = emitter.emit(light.widget, at: .zero, placement: .flow, indentLevel: 1)

        let palette = emitter.palette.stylesheet
        let html = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(HTMLEmitter.escape(title))</title>
            <style>
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
            /* The width the document was laid out against becomes a maximum
               rather than a fixed size: it's the measure the design was
               composed for, but a narrower viewport gets to reflow into
               whatever room it has. This is the requested width, not the
               committed one — a view that shrank to its content still gets to
               grow back to the measure the author had in mind. The height is
               left to the content. */
            #root { max-width: \(size.x)px; }
            \(palette.isEmpty ? "" : palette + "\n")\(emitter.interner.stylesheet)
            </style>
            </head>
            <body>
            <div id="root">
            \(body)
            </div>
            </body>
            </html>
            """

        return RenderResult(html: html, size: light.size, geometryMismatches: mismatches)
    }

    /// Lays out a view in a single color scheme.
    ///
    /// The height is proposed as unspecified rather than as `size.y`. A
    /// document isn't a window: it scrolls, so its height is an outcome of
    /// layout rather than a constraint on it. Proposing a finite height instead
    /// makes ``Text`` truncate to fit — that's its documented behaviour, and it
    /// is the right one on screen — but here the browser would still wrap the
    /// full string inside an element sized for the truncated one, so every text
    /// that needed a second line would spill over whatever was placed beneath
    /// it. Leaving the height unspecified is the ideal-height context that
    /// ``Text`` asks for.
    ///
    /// The width stays a real constraint: that's what text wraps against.
    private static func layOut(
        _ view: some View,
        size: SIMD2<Int>,
        colorScheme: ColorScheme
    ) -> (widget: StaticHTMLBackend.Widget, size: SIMD2<Int>) {
        let backend = StaticHTMLBackend(colorScheme: colorScheme)
        let window = backend.createWindow(withDefaultSize: size, id: "static-html")
        let environment = EnvironmentValues(backend: backend)
            .with(\.window, window)
            .with(\.colorScheme, colorScheme)

        let node = ViewGraphNode(for: view, backend: backend, environment: environment)
        let layout = node.computeLayout(
            proposedSize: ProposedViewSize(Double(size.x), nil),
            environment: environment
        )
        _ = node.commit()

        return (node.widget, layout.size.vector)
    }

    /// Assigns every escape-hatch request in a tree to its owning widget.
    ///
    /// A request is in scope for the modified view and everything beneath it,
    /// but only leaf widgets get an environment from the core, so a request is
    /// only ever recorded on leaves. The widget that should actually carry it
    /// is the modified view itself — the topmost widget whose entire subtree
    /// is covered by that request.
    ///
    /// Hoisting each request to that widget recovers the intended element even
    /// though containers never see an environment. See the seam note in
    /// ``StaticHTMLBackend/Widget/pendingTagRequest``.
    private static func resolveIntent(in root: StaticHTMLBackend.Widget) {
        let coverage = hoistRequests(in: root)
        // A request covering the whole tree has no ancestor left to hoist to,
        // so it belongs to the root.
        if let tag = coverage.tag {
            assign(tag, to: coverage)
        }
        if let attributes = coverage.attributes {
            assign(attributes, to: coverage)
        }
    }

    /// The requests covering an entire subtree.
    private struct Coverage {
        /// The widget the subtree is rooted at, which is the widget that takes
        /// ownership of any request that covers exactly this subtree.
        var owner: StaticHTMLBackend.Widget?
        /// The tag request covering every leaf below, if they all share one.
        var tag: HTMLTagRequest?
        /// The attributes request covering every leaf below, if they all share
        /// one.
        var attributes: HTMLAttributesRequest?
        /// Whether the subtree contained any widget at all that could carry a
        /// request.
        var isEmpty = true
    }

    /// Assigns requests within a subtree, returning what still covers all of
    /// it.
    ///
    /// A request that covers the whole subtree is left unassigned so that an
    /// ancestor can claim it instead; anything that only covers part of the
    /// subtree has found its owner here.
    private static func hoistRequests(in widget: StaticHTMLBackend.Widget) -> Coverage {
        let children = widget.getChildren()

        guard !children.isEmpty else {
            // A structural wrapper (Container, ScrollContainer) with no
            // children has no content, not "content that happens to carry no
            // tag" — an empty OptionalView (if without else) or an empty
            // Group is exactly this shape. Reporting isEmpty here, the same
            // as a widget with no populated descendants at all, keeps it from
            // vetoing a shared ancestor request the way a real, untagged leaf
            // legitimately would: deepestCommonRequest reads any concrete
            // (even nil) tag from every populated sibling as meaningful, so
            // one that never had a chance to hold one has to be excluded
            // instead of read as "explicitly untagged".
            let isStructuralWrapper = widget is StaticHTMLBackend.Container
                || widget is StaticHTMLBackend.ScrollContainer
            return Coverage(
                owner: widget,
                tag: widget.pendingTagRequest,
                attributes: widget.pendingAttributesRequest,
                isEmpty: isStructuralWrapper
            )
        }

        let childCoverages = children.map { child in hoistRequests(in: child) }
        let populated = childCoverages.filter { !$0.isEmpty }

        guard let first = populated.first else {
            return Coverage()
        }

        // A widget wrapping a single child adds no element of its own worth
        // naming — modifiers stack up several of these around one view. Keep
        // the child as the owner so that a tag lands on the view the author
        // applied it to rather than on one of its wrappers.
        //
        // This has to check the actual child count, not populated.count: a
        // container holding an if-without-else or an empty Group alongside a
        // real child also ends up with exactly one populated coverage, but
        // it's a container the author gave multiple children, not a
        // transparent wrapper around a single one — its own tag (if it has
        // one) belongs on it, not hoisted past it onto the lone survivor.
        if children.count == 1, populated.count == 1, let inner = first.owner {
            return Coverage(
                owner: inner,
                tag: first.tag,
                attributes: first.attributes,
                isEmpty: false
            )
        }

        // The request this widget owns is the innermost one that covers all of
        // its children. A child that was given its own tag reports that one
        // instead, but the request it shadowed is still in its chain, so the
        // deepest request common to every chain is the one that belongs here.
        let sharedTag = deepestCommonRequest(
            populated.map(\.tag),
            enclosing: \.enclosing
        )
        let sharedAttributes = deepestCommonRequest(
            populated.map(\.attributes),
            enclosing: \.enclosing
        )

        // Anything a child reports beyond the shared request is its own, so it
        // is assigned to the child rather than hoisted any further.
        for coverage in populated {
            if let tag = coverage.tag, tag !== sharedTag {
                assign(tag, to: coverage)
            }
            if let attributes = coverage.attributes, attributes !== sharedAttributes {
                assign(attributes, to: coverage)
            }
        }

        return Coverage(
            owner: widget,
            tag: sharedTag,
            attributes: sharedAttributes,
            isEmpty: false
        )
    }

    /// Finds the innermost request that every one of a widget's children is
    /// covered by.
    ///
    /// Each child reports the innermost request in scope for it, which is its
    /// own if the author gave it one. Because a request keeps a reference to
    /// the one it shadowed, walking a child's chain enumerates every request
    /// covering that child, outermost last. The request a parent owns is then
    /// the first entry of any child's chain that appears in all of them.
    ///
    /// - Parameters:
    ///   - requests: The innermost request reported by each child, in order.
    ///   - enclosing: The key path from a request to the one it shadowed.
    /// - Returns: The innermost request covering every child, if there is one.
    private static func deepestCommonRequest<Request: AnyObject>(
        _ requests: [Request?],
        enclosing: KeyPath<Request, Request?>
    ) -> Request? {
        guard let first = requests.first, requests.allSatisfy({ $0 != nil }) else {
            // A child covered by no request at all rules out every candidate:
            // nothing can cover the whole set.
            return nil
        }

        let chains = requests.map { request in
            sequence(first: request, next: { $0?[keyPath: enclosing] })
                .compactMap { $0 }
        }
        let others = chains.dropFirst().map { chain in
            chain.map(ObjectIdentifier.init)
        }

        return sequence(first: first, next: { $0?[keyPath: enclosing] })
            .compactMap { $0 }
            .first { candidate in
                let identity = ObjectIdentifier(candidate)
                return others.allSatisfy { $0.contains(identity) }
            }
    }

    /// Records a request as belonging to the widget a coverage came from.
    private static func assign(_ tag: HTMLTagRequest, to coverage: Coverage) {
        coverage.owner?.explicitElement = tag.element
    }

    /// Records a request as belonging to the widget a coverage came from.
    private static func assign(_ attributes: HTMLAttributesRequest, to coverage: Coverage) {
        coverage.owner?.authorAttributes = attributes.attributes
    }

    /// Copies each widget's dark-scheme colors onto the corresponding widget
    /// from the light pass.
    ///
    /// The two trees are structurally identical (same view, same proposed
    /// size), so they can be walked in lockstep.
    private static func mergeColors(
        from dark: StaticHTMLBackend.Widget,
        into light: StaticHTMLBackend.Widget
    ) {
        switch (light, dark) {
            case (
            let lightText as StaticHTMLBackend.TextView,
            let darkText as StaticHTMLBackend.TextView
        ):
                if let lightColor = lightText.color, let darkColor = darkText.color {
                    lightText.color = SchemePair(light: lightColor.light, dark: darkColor.dark)
                }
            case (
            let lightRectangle as StaticHTMLBackend.Rectangle,
            let darkRectangle as StaticHTMLBackend.Rectangle
        ):
                if let lightColor = lightRectangle.color, let darkColor = darkRectangle.color {
                    lightRectangle.color = SchemePair(
                        light: lightColor.light,
                        dark: darkColor.dark
                    )
                }
            default:
                break
        }

        let lightChildren = light.getChildren()
        let darkChildren = dark.getChildren()
        guard lightChildren.count == darkChildren.count else {
            return
        }
        for (lightChild, darkChild) in zip(lightChildren, darkChildren) {
            mergeColors(from: darkChild, into: lightChild)
        }
    }

    /// Collects the geometry differences between two laid-out trees.
    private static func geometryMismatches(
        between light: StaticHTMLBackend.Widget,
        and dark: StaticHTMLBackend.Widget
    ) -> [GeometryMismatch] {
        var mismatches: [GeometryMismatch] = []
        if light.size != dark.size {
            mismatches.append(
                GeometryMismatch(
                    tag: light.tag ?? "Widget",
                    lightSize: light.size,
                    darkSize: dark.size
                )
            )
        }

        let lightChildren = light.getChildren()
        let darkChildren = dark.getChildren()
        guard lightChildren.count == darkChildren.count else {
            return mismatches
        }
        for (lightChild, darkChild) in zip(lightChildren, darkChildren) {
            mismatches += geometryMismatches(between: lightChild, and: darkChild)
        }
        return mismatches
    }
}
