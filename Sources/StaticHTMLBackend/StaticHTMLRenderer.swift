import Foundation
@_spi(Backends) import SwiftCrossUI
import SwiftCrossUIComponents

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
        emitter.emitsViewIdentity = context.emitsViewIdentity
        emitter.declaredSlots = context.customSlots

        // A custom slot is emitted from inside the body, where a HTMLSlot
        // sits, so its items have to be registered before the body runs — the
        // marker reads the registry as the emitter reaches it. Head and
        // bodyEnd items are drained after the body instead (see below), which
        // is what gives contributions their first-appearance position ahead of
        // the page owner's.
        func isCustomSlot(_ item: HTMLDocumentItem) -> Bool {
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
            metadata: metadata(from: registry),
            imagesMissingAltText: emitter.imagesMissingAltText,
            hrefsWithoutConsumer: unconsumedHrefs(in: light.widget)
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
        func partition(_ slot: HTMLDocumentItem
            .Slot) -> (contributed: [HTMLDocumentItem], owned: [HTMLDocumentItem])
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
        let document = emitter.documentStylesheet
        let properties = [palette, typeScale, document]
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

    /// Resolves the escape-hatch values a tree captured onto the elements
    /// that carry them.
    ///
    /// A tag and an `id`-bearing block are captured onto the widget of the
    /// view they name, so only the values whose consumer isn't their
    /// application site need resolving here: a non-`id` block, consumed
    /// beneath its site, and a navigation destination, consumed at every
    /// href-capable view within its scope during the update.
    private static func resolveIntent(in root: StaticHTMLBackend.Widget) {
        resolveRawFragments(in: root)
        sinkMaterializedValues(in: root)
        sinkAttributes(in: root)

        sinkTapMarkers(in: root)
        sinkCornerRadii(in: root)
        markControlLabels(in: root)

        var identifierCounter = 0
        associateLabels(in: root, counter: &identifierCounter)
    }

    /// Moves each corner radius down onto the element that owns the box it
    /// rounds.
    ///
    /// `CornerRadiusModifier` produces a wrapper of its own, so the radius
    /// starts one element above the box it is meant to round. Left there, the
    /// clip that comes with it (`overflow:hidden`) cuts a box the rounded
    /// content is merely nested inside: a `.background()` pair's backdrop is
    /// absolutely positioned within the *pair's* stacking context, so a clip
    /// established on an ancestor of that context does not shape it and the
    /// backdrop paints square corners over the rounded ones.
    ///
    /// Sinking the radius puts `border-radius`, `overflow:hidden`,
    /// `isolation:isolate`, and `position:relative` on one element, which is
    /// what makes the clip reach the backdrop. It also removes the wrapper's
    /// last reason to exist, so elision can take it.
    ///
    /// Descent follows single-child wrapping only, the same shape
    /// ``sinkTapMarkers(in:)`` uses: a wrapper adds no box worth rounding, so
    /// the radius belongs to the one view beneath it. It stops at a widget
    /// that already carries a radius (the inner one is the author's own, more
    /// specific answer), at a control owning its label subtree, and at any
    /// widget with zero or several children — rounding one of a group would be
    /// a guess, and the wrapper really is the box in that case.
    ///
    /// - Parameter widget: The subtree to walk.
    private static func sinkCornerRadii(in widget: StaticHTMLBackend.Widget) {
        let children = widget.getChildren()
        if widget.cornerRadius > 0, children.count == 1, let child = children.first,
           child.cornerRadius == 0,
           !(widget is StaticHTMLBackend.ViewLabelButton)
        {
            child.cornerRadius = widget.cornerRadius
            widget.cornerRadius = 0
        }
        for child in children {
            sinkCornerRadii(in: child)
        }
    }

    /// Moves each tap marker down onto the element the author made tappable.
    ///
    /// `OnTapGestureModifier` produces a wrapper widget of its own, so the
    /// flag starts on the wrapper rather than on the content. Left there it
    /// would mark a `<div>` around a control that carries its own marker, so a
    /// tapped `Button` would emit two markers for one interaction and the
    /// enlivening tier would have to guess which element it was meant to bind.
    ///
    /// Descent follows single-child wrapping only, the same shape
    /// ``sinkMaterializedValues(in:)`` takes to the author's modified view: a
    /// wrapper adds no element worth marking, so the marker belongs to the one
    /// view beneath it. A wrapper around several children keeps the marker
    /// itself — the author made that whole group tappable, and picking one
    /// child would be a guess.
    ///
    /// Descent also stops at a control that owns its label subtree: a
    /// view-label button is a single-child widget, but it becomes the element
    /// the reader activates, so sinking the marker onto its label would mark
    /// the text inside the control rather than the control.
    ///
    /// - Parameter widget: The subtree to walk.
    private static func sinkTapMarkers(in widget: StaticHTMLBackend.Widget) {
        let children = widget.getChildren()
        if widget.awaitsTapEnlivening, children.count == 1, let child = children.first,
           !(widget is StaticHTMLBackend.ViewLabelButton)
        {
            widget.awaitsTapEnlivening = false
            child.awaitsTapEnlivening = true
        }
        for child in children {
            sinkTapMarkers(in: child)
        }
    }

    /// Flags every widget inside a ``StaticHTMLBackend/ViewLabelButton``'s
    /// label subtree, so heading derivation can exclude it.
    ///
    /// A button's label carries a declared text style for the same reason
    /// any other text does — to look right — not to claim a place in the
    /// document outline. Nothing about being a control's label changes what
    /// element the label renders as (a `Text` inside one still becomes a
    /// `<span>`, still gets styled from its font), so this only affects
    /// whether ``HTMLEmitter`` treats a heading-mapped font as an outline
    /// entry; see the `Text` case in
    /// ``HTMLEmitter/emit(_:at:placement:indentLevel:inheritedFrame:stretchesUndeclaredAxis:flexShrinkWeight:)``.
    ///
    /// - Parameter widget: The subtree to walk.
    private static func markControlLabels(in widget: StaticHTMLBackend.Widget) {
        if let button = widget as? StaticHTMLBackend.ViewLabelButton {
            markInsideControlLabel(button.label)
        }
        for child in widget.getChildren() {
            markControlLabels(in: child)
        }
    }

    /// Marks every widget in a subtree as sitting inside a control's label.
    ///
    /// - Parameter widget: The subtree to mark.
    private static func markInsideControlLabel(_ widget: StaticHTMLBackend.Widget) {
        widget.isInsideControlLabel = true
        for child in widget.getChildren() {
            markInsideControlLabel(child)
        }
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
    /// Unlike a tag request, this one never hoists. ``HTMLRawFragment`` puts
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

    /// The child a value applied at a widget descends into, or `nil` where the
    /// widget is itself the element the value names.
    ///
    /// A wrapper around one view adds no element worth naming, so the value
    /// belongs to the view inside it. A `.background()` pair is the other
    /// shape that has a single "the content": its children are always
    /// `[backdrop, content]`, and a value applied outside the pair was applied
    /// to the content, not to the decoration the modifier supplied. Every
    /// other multi-child widget holds peers — a stack's children, a
    /// `ForEach`'s rows — where no child is more the content than its
    /// siblings, so the value stops at the widget itself.
    ///
    /// - Parameter widget: The widget to descend from.
    /// - Returns: The child to descend into, if there is one.
    private static func descentTarget(
        of widget: StaticHTMLBackend.Widget
    ) -> StaticHTMLBackend.Widget? {
        let children = widget.getChildren()
        if let container = widget as? StaticHTMLBackend.Container,
           container.isBackgroundLayering, children.count == 2
        {
            return children[1]
        }
        return children.count == 1 ? children[0] : nil
    }

    /// Gives each materializing value the element of the view it was applied
    /// to.
    ///
    /// A tag and an `id`-bearing block both name the author's modified view.
    /// The modifier owns a wrapper *around* that view rather than the view's
    /// own widget, so the value descends from the wrapper to what the author
    /// was describing — never past it. Where that view emits a real element
    /// the value lands on it (an `id` on a `Button` reaches the `<button>`
    /// itself, minting no wrapper); where it would otherwise elide, carrying
    /// the value is what keeps it.
    ///
    /// Descent follows single-child wrapping and a `.background()` pair's
    /// content side, and stops at a control that owns its label subtree: the
    /// control is the element the author named, so handing the value to the
    /// label would put it inside the button rather than on it. A wrapper
    /// carrying a value of its own doesn't stop it — stacked applications are
    /// separate wrappers naming the same element, so they descend to the same
    /// site and resolve there.
    ///
    /// Children resolve first, so an application closer to the content claims
    /// the site before one further out reaches it, which is what makes the
    /// innermost call win a key two of them both set.
    ///
    /// - Parameter widget: The subtree to walk.
    private static func sinkMaterializedValues(in widget: StaticHTMLBackend.Widget) {
        for child in widget.getChildren() {
            sinkMaterializedValues(in: child)
        }

        let element = widget.pendingElement
        let block = widget.pendingIdentifiedAttributes
        guard element != nil || block != nil else {
            return
        }
        widget.pendingElement = nil
        widget.pendingIdentifiedAttributes = nil

        var site = widget
        while !(site is StaticHTMLBackend.ViewLabelButton), let next = descentTarget(of: site) {
            site = next
        }

        if let element {
            // A name already on the site was applied closer to the content,
            // which is the more specific answer.
            site.explicitElement = site.explicitElement ?? element
        }
        if let block {
            site.authorAttributes.merge(block.attributes) { existing, _ in existing }
        }
    }

    /// Moves each non-`id` attribute block onto the element that survives to
    /// carry it.
    ///
    /// A block without an `id` describes whatever element ends up holding the
    /// content, not a node the author pinned, so it rides down from the
    /// wrapper that captured it through wrappers that emit nothing, and lands
    /// on the first one that materializes. The consumer is unambiguous because
    /// only a single-child wrapper elides: where descent could branch, the
    /// widget is a real element and consumes the block itself.
    ///
    /// Descent stops at a control that owns its label subtree. A view-label
    /// button is a single-child widget, but it becomes the element the reader
    /// activates, so an attribute meant for it belongs on the control rather
    /// than on the text inside it.
    ///
    /// - Parameter widget: The subtree to walk.
    private static func sinkAttributes(in widget: StaticHTMLBackend.Widget) {
        if let block = widget.pendingAttributes {
            widget.pendingAttributes = nil
            let consumer = consumer(from: widget)
            consumer.authorAttributes.merge(block.attributes) { existing, _ in
                // A block already resolved onto the consumer was applied
                // closer to the content than this one, so it stays.
                existing
            }
        }
        for child in widget.getChildren() {
            sinkAttributes(in: child)
        }
    }

    /// The element a value applied at `widget` is consumed by.
    ///
    /// Descent follows the widgets that describe the same content: a wrapper
    /// around one view names the same thing the view does, so an attribute
    /// meant for "this view" belongs on the innermost element rather than on
    /// the box some modifier put around it. A frame is not a reason to stop —
    /// `.frame()` sizes the content, it doesn't become a different subject —
    /// but a control that owns its label is, since the control is the element
    /// the reader interacts with and the author was describing.
    ///
    /// - Parameter widget: The application site.
    /// - Returns: The widget whose element carries the value.
    private static func consumer(
        from widget: StaticHTMLBackend.Widget
    ) -> StaticHTMLBackend.Widget {
        var current = widget
        while !(current is StaticHTMLBackend.ViewLabelButton),
              current.authorAttributes.isEmpty,
              current.explicitElement == nil,
              let next = descentTarget(of: current)
        {
            current = next
        }
        return current
    }

    /// Every navigation destination that reached no consumer.
    ///
    /// An `.href(_:)` whose subtree holds no href-capable view emits nothing
    /// at all — a container that merely holds content is not itself a
    /// destination. Nothing in the markup distinguishes that from a modifier
    /// that was never written, so it is reported here instead.
    ///
    /// - Parameter widget: The subtree to walk.
    /// - Returns: The unconsumed destinations, in tree order, deduplicated.
    private static func unconsumedHrefs(in widget: StaticHTMLBackend.Widget) -> [String] {
        var found: [String] = []
        func walk(_ widget: StaticHTMLBackend.Widget) {
            if let href = widget.pendingHref, !found.contains(href) {
                found.append(href)
            }
            for child in widget.getChildren() {
                walk(child)
            }
        }
        walk(widget)
        return found
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
