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
        /// The document's structured self-description — title, heading
        /// outline, and registered metadata.
        ///
        /// Additive: every value here was already produced somewhere inside
        /// the render and discarded once emitted into markup. A consumer
        /// that needs this data (a sitemap builder, say) reads it from here
        /// instead of parsing `html` back out.
        public var documentInfo: DocumentInfo
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
    ///   - context: What the page owner has to say about the document —
    ///     its title, the items it carries, where its assets go.
    ///   - size: The size to lay the view out against. Only the width is a
    ///     constraint; see the note on height in ``layOut(_:size:colorScheme:)``.
    /// - Returns: The rendered document along with anything notable observed
    ///   while producing it.
    public static func render(
        _ view: some View,
        context: DocumentContext,
        size: SIMD2<Int> = SIMD2(800, 600)
    ) -> RenderResult {
        // One registry spans both layout passes. The passes are structurally
        // identical, so the second one re-registers exactly what the first did
        // and dedupe absorbs it — sharing the registry rather than discarding
        // one is what keeps a contribution's first-appearance order meaningful.
        let registry = HTMLFragmentRegistry()

        let light = layOut(view, size: size, colorScheme: .light, registry: registry)
        let dark = layOut(view, size: size, colorScheme: .dark, registry: registry)

        let mismatches = geometryMismatches(between: light.widget, and: dark.widget)
        mergeColors(from: dark.widget, into: light.widget)
        resolveIntent(in: light.widget)

        var emitter = HTMLEmitter(headingMap: context.headingMap)
        emitter.registry = registry
        emitter.assetStore = context.assetStore
        emitter.inlineAssetThreshold = context.inlineAssetThreshold
        emitter.declaredSlots = context.customSlots

        // A custom slot is emitted from inside the body, where a SlotComponent
        // sits, so its items have to be registered before the body runs — the
        // marker reads the registry as the emitter reaches it. Head and
        // bodyEnd items are drained after the body instead (see below), which
        // is what gives contributions their first-appearance position ahead of
        // the page owner's.
        func isCustomSlot(_ item: FragmentItem) -> Bool {
            if case .custom = item.slot { true } else { false }
        }
        let documentItems = context.items.filter { !isCustomSlot($0) }
        for item in context.items where isCustomSlot(item) {
            registry.register(item)
        }

        // Emitting the body first is what makes built-in machinery conditional:
        // the emitter registers a construct's assets as it emits that
        // construct, so a page with no stacks carries no stack script. Draining
        // the registry before the body ran would collect only what the view
        // tree contributed.
        let body = emitter.emit(light.widget, at: .zero, placement: .flow, indentLevel: 1)

        // The reset registers last so that a page owner's item under the
        // reserved key already holds the slot and this one dedupes away. See
        // HTMLFragmentRegistry.resetItem().
        for item in documentItems {
            registry.register(item)
        }
        registry.register(HTMLFragmentRegistry.resetItem())

        let html = document(
            body: body,
            context: context,
            registry: registry,
            emitter: emitter
        )

        let documentInfo = DocumentInfo(
            title: context.title,
            headings: emitter.headings,
            metadata: metadata(from: registry)
        )

        return RenderResult(
            html: html,
            size: light.size,
            geometryMismatches: mismatches,
            documentInfo: documentInfo
        )
    }

    /// Derives ``DocumentInfo/metadata`` from every `.meta` item the render
    /// registered.
    ///
    /// Reads the registry directly rather than re-deriving from
    /// `context.items`, since a component contributing a meta tag through the
    /// view tree is exactly as much "the document's metadata" as one the page
    /// owner declared on ``DocumentContext`` — the registry is where both
    /// already converge, deduplicated.
    ///
    /// - Parameter registry: The registry the render populated.
    /// - Returns: The registered meta tags' `content` values, keyed by the
    ///   standard key matching their `name`/`property` attribute where one
    ///   exists.
    private static func metadata(from registry: HTMLFragmentRegistry) -> [DocumentInfoKey: String] {
        var metadata: [DocumentInfoKey: String] = [:]
        for item in registry.allItems {
            guard case .meta(let attributes) = item.content, let content = attributes["content"]
            else {
                continue
            }
            for attributeName in ["name", "property"] {
                guard let rawName = attributes[attributeName] else {
                    continue
                }
                metadata[.standardOrCustom(rawName)] = content
            }
        }
        return metadata
    }

    /// Assembles the document around an emitted body.
    ///
    /// Source order follows the progressive-enhancement design: the head
    /// carries only what first paint needs, and everything else rides at the
    /// end of the body, where it costs nothing before the content is readable.
    private static func document(
        body: String,
        context: DocumentContext,
        registry: HTMLFragmentRegistry,
        emitter: HTMLEmitter
    ) -> String {
        // Contributions come first within a slot and the page owner's items
        // last, so the page owner overrides anything a component asked for.
        // Splitting them here rather than relying on registration order keeps
        // that guarantee independent of when the renderer happened to drain
        // each source.
        let ownerKeys = Set(context.items.map(\.key))
        func partition(_ slot: FragmentItem
            .Slot) -> (contributed: [FragmentItem], owned: [FragmentItem])
        {
            let items = registry.items(in: slot)
            return (
                items.filter { !ownerKeys.contains($0.key) },
                items.filter { ownerKeys.contains($0.key) }
            )
        }

        let head = partition(.head)
        let tail = partition(.bodyEnd)

        // The reset is a head contribution, but it has to precede the interned
        // stylesheet rather than follow the other contributions: a registered
        // .style is expected to be able to override an interned property (the
        // future geometry selectors' display:none gates depend on winning that
        // tie on source order), which only holds if contributions come after
        // the interned block, and the reset comes before it.
        let reset = head.contributed.filter { $0.key == .reset }
        let headContributions = head.contributed.filter { $0.key != .reset }

        // Custom-property definitions lead the block: the interned classes
        // below reference them with var(…), and the type scale's @media
        // override has to be able to re-point those references at a narrower
        // viewport without the class bodies changing at all.
        let palette = emitter.palette.stylesheet
        let typeScale = emitter.typeScale.stylesheet
        // Zero-specificity (`:where`), so an interned class or a registered
        // contribution still outranks it, the same contract the reset holds.
        let tables = emitter.tableStylesheet
        let properties = [palette, typeScale, tables]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let baseline = ([reset.map { $0.rendered(indent: "") }.joined(separator: "\n")]
            + [
                properties.isEmpty && emitter.interner.stylesheet.isEmpty
                    ? "" : """
                        <style>
                        \(properties.isEmpty ? "" : properties + "\n")\(emitter.interner.stylesheet)
                        </style>
                        """
            ])
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let headItems = (headContributions + head.owned)
            .map { $0.rendered(indent: "") }
            .joined(separator: "\n")
        let tailItems = (tail.contributed + tail.owned)
            .map { $0.rendered(indent: "") }
            .joined(separator: "\n")

        let headBlock = [baseline, headItems].filter { !$0.isEmpty }.joined(separator: "\n")
        let tailBlock = tailItems.isEmpty ? "" : "\n" + tailItems

        return """
            <!DOCTYPE html>
            <html lang="\(HTMLEmitter.escape(context.language))">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(HTMLEmitter.escape(context.title))</title>
            \(headBlock)
            </head>
            <body>
            <div id="root">
            \(body)
            </div>\(tailBlock)
            </body>
            </html>
            """
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
        colorScheme: ColorScheme,
        registry: HTMLFragmentRegistry
    ) -> (widget: StaticHTMLBackend.Widget, size: SIMD2<Int>) {
        let backend = StaticHTMLBackend(colorScheme: colorScheme)
        let window = backend.createWindow(withDefaultSize: size, id: "static-html")
        let environment = EnvironmentValues(backend: backend)
            .with(\.window, window)
            .with(\.colorScheme, colorScheme)
            .with(\.htmlFragmentRegistry, registry)

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
        resolveRawFragments(in: root)

        let coverage = hoistRequests(in: root)
        // A request covering the whole tree has no ancestor left to hoist to,
        // so it belongs to the root.
        if let tag = coverage.tag {
            assign(tag, to: coverage)
        }
        if let attributes = coverage.attributes {
            assign(attributes, to: coverage)
        }
        if let href = coverage.href {
            assign(href, to: coverage)
        }

        var identifierCounter = 0
        associateLabels(in: root, counter: &identifierCounter)
    }

    /// Wires each unlabelled control to the text that names it.
    ///
    /// A control and its label are separate views: `Toggle` expands to an
    /// `HStack { Text(label); ToggleSwitch() }` in user space, so by the time
    /// the backend sees them they're siblings with nothing recording that one
    /// names the other. Emitted as-is that leaves a control with no accessible
    /// name at all — the same `Toggle` a native backend reports to the
    /// accessibility tree as `AXCheckBox title="Include drafts"` arrives on
    /// the web nameless.
    ///
    /// `aria-labelledby` rather than a wrapping `<label for>`: the label text
    /// and the control are already siblings inside a stack whose flex layout
    /// positions them, so introducing a `<label>` element around the pair
    /// would insert a box into the middle of that layout. A reference wires
    /// the two without changing the emitted structure at all.
    ///
    /// - Parameters:
    ///   - widget: The subtree to walk.
    ///   - counter: Source of unique `id` values across the document.
    private static func associateLabels(
        in widget: StaticHTMLBackend.Widget,
        counter: inout Int
    ) {
        let children = widget.getChildren()

        // The pairing has to be unambiguous to be worth making: exactly one
        // text and exactly one control among the children. Anything else — two
        // labels, two controls, a control alone — is a layout the author built
        // for themselves, and guessing at it would attach a name that isn't
        // the one they meant.
        let texts = children.compactMap { $0 as? StaticHTMLBackend.TextView }
        let controls = children.filter(isLabellableControl)
        if texts.count == 1, controls.count == 1,
           let label = texts.first, let control = controls.first,
           control.labelledBy == nil, !label.content.isEmpty
        {
            let identifier = label.referencedIdentifier ?? "scui-label-\(counter)"
            counter += 1
            label.referencedIdentifier = identifier
            control.labelledBy = identifier
        }

        for child in children {
            associateLabels(in: child, counter: &counter)
        }
    }

    /// Whether a widget is a control that needs an accessible name it can't
    /// supply itself.
    ///
    /// A `ToggleButton` and a `Button` are excluded: their label is their own
    /// text content, which already names them.
    private static func isLabellableControl(_ widget: StaticHTMLBackend.Widget) -> Bool {
        widget is StaticHTMLBackend.Checkbox
            || widget is StaticHTMLBackend.Switch
            || widget is StaticHTMLBackend.Slider
            || widget is StaticHTMLBackend.TextField
    }

    /// Assigns each raw-fragment request to the leaf that carries it.
    ///
    /// Unlike a tag request, this one never hoists. ``RawHTMLFragment`` puts
    /// the request in scope for exactly one zero-size leaf of its own making,
    /// so the leaf reporting it *is* the view the author wrote — there's no
    /// ambiguity about which element the payload replaces, and hoisting it to
    /// an ancestor would swallow that ancestor's real content.
    private static func resolveRawFragments(in widget: StaticHTMLBackend.Widget) {
        let children = widget.getChildren()
        if children.isEmpty {
            widget.rawFragment = widget.pendingRawFragmentRequest
        }
        for child in children {
            resolveRawFragments(in: child)
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
        /// The href request covering every leaf below, if they all share one.
        var href: HTMLHrefRequest?
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
                href: widget.pendingHrefRequest,
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
                href: first.href,
                isEmpty: false
            )
        }

        // A `.background()` pair has several children but only one of them is
        // the view the author wrapped; the other is decoration the modifier
        // supplied. Ownership follows the content child for the same reason
        // the single-child case above hands ownership down: an element name,
        // an href, or an attribute set the author applied outside the pair
        // was applied to the content, not to the backdrop and not to the
        // pair. Without this, a single-valued request stops at the pair and
        // reaches no element at all, since nothing consumes one on a
        // container.
        if let contentIndex = contentChildIndex(of: widget),
           childCoverages.indices.contains(contentIndex),
           let content = childCoverages[contentIndex].owner
        {
            let contentCoverage = childCoverages[contentIndex]

            // A request from outside the pair is in scope for every child, so
            // the decoration children report it too. Only what a decoration
            // child reports *beyond* that is genuinely its own — a
            // `.htmlTag()` applied to the backdrop view itself, say — and
            // only that gets assigned here. Assigning the shared request as
            // well would put the author's single element name, or their
            // single href, on the backdrop and the content both: two elements
            // for one request, and nested anchors where there should be one.
            for (index, coverage) in childCoverages.enumerated()
                where index != contentIndex && !coverage.isEmpty
            {
                if let tag = coverage.tag, tag !== contentCoverage.tag {
                    assign(tag, to: coverage)
                }
                if let attributes = coverage.attributes,
                   attributes !== contentCoverage.attributes
                {
                    assign(attributes, to: coverage)
                }
                if let href = coverage.href, href !== contentCoverage.href {
                    assign(href, to: coverage)
                }
            }

            return Coverage(
                owner: content,
                tag: contentCoverage.tag,
                attributes: contentCoverage.attributes,
                href: contentCoverage.href,
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
        let sharedHref = deepestCommonRequest(
            populated.map(\.href),
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
            if let href = coverage.href, href !== sharedHref {
                assign(href, to: coverage)
            }
        }

        return Coverage(
            owner: widget,
            tag: sharedTag,
            attributes: sharedAttributes,
            href: sharedHref,
            isEmpty: false
        )
    }

    /// The index of the child that is a multi-child wrapper's content, if the
    /// wrapper has a designated content side at all.
    ///
    /// Only ``StaticHTMLBackend/Container/isBackgroundLayering`` pairs qualify
    /// today: their children are always exactly `[backdrop, content]`, so the
    /// content is index 1. Every other multi-child container in the backend
    /// holds peers — a stack's children, a `ForEach`'s rows, the branches of
    /// a `TupleView` — where no child is more "the" content than its
    /// siblings, and a request covering all of them belongs to the container.
    ///
    /// - Parameter widget: The widget to classify.
    /// - Returns: The content child's index, or `nil` for a widget whose
    ///   children are peers.
    private static func contentChildIndex(of widget: StaticHTMLBackend.Widget) -> Int? {
        guard let container = widget as? StaticHTMLBackend.Container,
              container.isBackgroundLayering,
              container.children.count == 2
        else {
            return nil
        }
        return 1
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
    ///
    /// Unlike the tag/href cases, this doesn't just take `attributes.attributes`
    /// — it merges the whole `enclosing` chain (see `mergedAttributes(from:)`),
    /// because `HTMLAttributesRequest` is dictionary-valued: several stacked
    /// `.htmlAttributes(_:)` calls all deserve to reach the element, not just
    /// the innermost one.
    private static func assign(_ attributes: HTMLAttributesRequest, to coverage: Coverage) {
        coverage.owner?.authorAttributes = mergedAttributes(from: attributes)
    }

    /// Unions a chain of `HTMLAttributesRequest`s into one dictionary.
    ///
    /// Walks from `request` outward through `enclosing`, so the request
    /// closest to the content is visited first. A dictionary merge keeps the
    /// FIRST value it sees per key (`uniquingKeysWith` never overwrites once
    /// a key exists), which is exactly innermost-wins-per-key: the request
    /// closest to the content sets a key before any outer request gets a
    /// chance to.
    ///
    /// - Parameter request: The innermost request in the chain to merge.
    /// - Returns: Every key from every request in the chain, each key's
    ///   value taken from the innermost request that set it.
    private static func mergedAttributes(from request: HTMLAttributesRequest) -> [String: String] {
        var merged: [String: String] = [:]
        var current: HTMLAttributesRequest? = request
        while let node = current {
            merged.merge(node.attributes) { keepInner, _ in keepInner }
            current = node.enclosing
        }
        return merged
    }

    /// Records a request as belonging to the widget a coverage came from.
    private static func assign(_ href: HTMLHrefRequest, to coverage: Coverage) {
        coverage.owner?.href = href.href
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
            case (
            let lightPath as StaticHTMLBackend.PathWidget,
            let darkPath as StaticHTMLBackend.PathWidget
        ):
                if let lightColor = lightPath.fillColor, let darkColor = darkPath.fillColor {
                    lightPath.fillColor = SchemePair(
                        light: lightColor.light,
                        dark: darkColor.dark
                    )
                }
                if let lightColor = lightPath.strokeColor, let darkColor = darkPath.strokeColor {
                    lightPath.strokeColor = SchemePair(
                        light: lightColor.light,
                        dark: darkColor.dark
                    )
                }
            case (
            let lightGradient as StaticHTMLBackend.GradientWidget,
            let darkGradient as StaticHTMLBackend.GradientWidget
        ):
                guard lightGradient.stops.count == darkGradient.stops.count else {
                    break
                }
                lightGradient.stops = zip(lightGradient.stops, darkGradient.stops)
                    .map { lightStop, darkStop in
                        StaticHTMLBackend.GradientStop(
                            color: SchemePair(
                                light: lightStop.color.light,
                                dark: darkStop.color.dark
                            ),
                            location: lightStop.location
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
