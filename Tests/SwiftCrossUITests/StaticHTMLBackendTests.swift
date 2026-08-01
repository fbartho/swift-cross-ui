import Testing

import StaticHTMLBackend
@_spi(Backends) import SwiftCrossUI

@Suite("Testing for the static HTML backend")
struct StaticHTMLBackendTests {
    @MainActor
    @Test("A heading's interned font size survives the #root reset")
    func headingFontSizeOutranksRootReset() {
        // #root is an id selector — (1,0,0) specificity — which would
        // outrank a heading's interned class (0,1,0) if the reset block
        // weren't wrapped in :where() to zero its own contribution. Without
        // that wrapper, every heading would compute to the browser's default
        // h1 size instead of the declared text style.
        let view = Text("Big Heading").font(.largeTitle)
        let html = StaticHTMLRenderer.render(view, title: "Specificity").html

        // The reset selector carries zero specificity of its own, so it
        // never wins a cascade tie against a heading's interned class.
        #expect(html.contains(":where(#root h1, #root h2"))
        #expect(!html.contains("#root :where(h1"))

        let headingRule = Self.styleRule(forElementContaining: "<h1", in: html)
        #expect(headingRule?.contains("font-size:26px") == true)
    }

    @MainActor
    @Test("A .background() Color sibling doesn't displace an ancestor's tag")
    func backgroundColorSiblingDoesNotDisplaceAncestorTag() {
        // Before a Color leaf could carry pendingTagRequest, it reported no
        // request at all, which reads as "not covered by anything" — and one
        // uncovered child is enough to rule out every candidate tag for the
        // whole subtree (see deepestCommonRequest). A .background(Color(...))
        // introduces exactly one such sibling, so it used to knock the tag
        // off the container it was applied to and take any derived headings
        // down with it.
        let view = VStack {
            Text("Title").font(.largeTitle)
            Text("Code block").background(Color.gray)
        }
        .htmlTag(.article)
        let html = StaticHTMLRenderer.render(view, title: "Background sibling").html

        #expect(html.contains("<article"))
        #expect(html.contains("<h1"))
        #expect(html.contains(">Title</h1>"))
    }

    @Test("Escaping covers every character that could break out of markup")
    func escapesMarkupCharacters() {
        #expect(HTMLEmitter.escape("a & b") == "a &amp; b")
        #expect(HTMLEmitter.escape("<script>") == "&lt;script&gt;")
        #expect(HTMLEmitter.escape("say \"hi\"") == "say &quot;hi&quot;")
        #expect(HTMLEmitter.escape("it's") == "it&#39;s")
        #expect(HTMLEmitter.escape("plain") == "plain")
    }

    @Test("Escaping ampersands doesn't double-escape the entities it produces")
    func escapesAmpersandOnce() {
        #expect(HTMLEmitter.escape("&lt;") == "&amp;lt;")
    }

    @Test("Identical styles share one generated class")
    func internsDuplicateStyles() {
        var interner = StyleInterner()

        var first = Style()
        first.set("10px", for: "width")
        first.set("red", for: "color")

        // Same declarations, added in the opposite order.
        var second = Style()
        second.set("red", for: "color")
        second.set("10px", for: "width")

        var third = Style()
        third.set("20px", for: "width")

        let firstName = interner.className(for: first)
        let secondName = interner.className(for: second)
        let thirdName = interner.className(for: third)

        #expect(firstName == secondName)
        #expect(firstName != thirdName)
        #expect(interner.stylesheet.contains(".scui-0 { color:red;width:10px }"))
        #expect(interner.stylesheet.contains(".scui-1 { width:20px }"))
    }

    @Test("Empty styles get no class")
    func skipsEmptyStyles() {
        var interner = StyleInterner()
        #expect(interner.className(for: Style()) == nil)
        #expect(interner.stylesheet.isEmpty)
    }

    @Test("Scheme-invariant colors become literals, not custom properties")
    func usesLiteralForSchemeInvariantColor() {
        var palette = ColorPalette()
        let grey = Color.Resolved(red: 0.5, green: 0.5, blue: 0.5)
        let value = palette.value(for: SchemePair(light: grey, dark: grey))

        #expect(value == "rgba(128,128,128,1.0)")
        #expect(palette.stylesheet.isEmpty)
    }

    @Test("Colors that differ between schemes become custom properties")
    func usesCustomPropertyForSchemeVaryingColor() {
        var palette = ColorPalette()
        let pair = SchemePair(
            light: Color.Resolved(red: 0, green: 0, blue: 0),
            dark: Color.Resolved(red: 1, green: 1, blue: 1)
        )

        #expect(palette.value(for: pair) == "var(--scui-c0)")
        // The same color asked for twice reuses the property.
        #expect(palette.value(for: pair) == "var(--scui-c0)")

        let stylesheet = palette.stylesheet
        #expect(stylesheet.contains("--scui-c0: rgba(0,0,0,1.0);"))
        #expect(stylesheet.contains("@media (prefers-color-scheme: dark)"))
        #expect(stylesheet.contains("--scui-c0: rgba(255,255,255,1.0);"))
    }

    @Test("Text styles map to their documented heading levels")
    func mapsTextStylesToHeadings() {
        let map = HeadingMap.default

        #expect(map.element(for: .largeTitle) == .h1)
        #expect(map.element(for: .title) == .h2)
        #expect(map.element(for: .title2) == .h3)
        #expect(map.element(for: .title3) == .h4)
    }

    @Test("Fonts that don't declare a heading produce none")
    func derivesNoHeadingWithoutDeclaredStyle() {
        let map = HeadingMap.default

        #expect(map.element(for: .body) == nil)
        #expect(map.element(for: .headline) == nil)
        #expect(map.element(for: nil) == nil)
        // A concrete size is not a declaration of intent, however large.
        #expect(map.element(for: .system(size: 96)) == nil)
    }

    @Test("Custom element names reject anything that isn't a tag name")
    func validatesCustomElementNames() {
        #expect(HTMLElement.isValidName("hgroup"))
        #expect(HTMLElement.isValidName("my-element"))
        #expect(HTMLElement.isValidName("h1"))

        #expect(!HTMLElement.isValidName(""))
        #expect(!HTMLElement.isValidName("1h"))
        #expect(!HTMLElement.isValidName("has space"))
        #expect(!HTMLElement.isValidName("<script>"))
        #expect(!HTMLElement.isValidName("-leading-hyphen"))
    }

    @Test("Named elements are always valid, custom ones are checked")
    func validatesElements() {
        #expect(HTMLElement.h1.isValid)
        #expect(HTMLElement.custom("hgroup").isValid)
        #expect(!HTMLElement.custom("not a tag").isValid)
    }

    @MainActor
    @Test("Declared text styles become headings in the emitted document")
    func emitsHeadingsFromDeclaredStyles() {
        let view = VStack {
            Text("Title").font(.largeTitle)
            Text("Section").font(.title)
            Text("Body")
        }
        let html = StaticHTMLRenderer.render(view, title: "Headings").html

        #expect(html.contains(">Title</h1>"))
        #expect(html.contains(">Section</h2>"))
        #expect(html.contains(">Body</span>"))
    }

    @MainActor
    @Test("An explicit tag overrides a derived heading")
    func explicitTagOverridesDerivedHeading() {
        let view = Text("Title").font(.largeTitle).htmlTag(.p)
        let html = StaticHTMLRenderer.render(view, title: "Override").html

        #expect(html.contains(">Title</p>"))
        #expect(!html.contains("<h1"))
    }

    @MainActor
    @Test("An explicit tag on a stack wraps the stack, not each child")
    func explicitTagAppliesToModifiedViewOnly() {
        let view = VStack {
            Text("One")
            Text("Two")
        }
        .htmlTag(.nav)
        let html = StaticHTMLRenderer.render(view, title: "Nav").html

        // The request is in scope for both children, but describes one element.
        #expect(html.components(separatedBy: "<nav").count - 1 == 1)
        #expect(html.contains(">One</span>"))
        #expect(html.contains(">Two</span>"))
    }

    @MainActor
    @Test("A child overriding the tag doesn't push its parent's tag onto its siblings")
    func containerTagSurvivesAnOverridingChild() {
        let view = VStack {
            Text("One")
            Text("Two")
            HStack {
                Text("Link")
            }
            .htmlTag(.nav)
        }
        .htmlTag(.header)
        let html = StaticHTMLRenderer.render(view, title: "Mixed").html

        // The header belongs to the stack the author put it on, even though
        // one child claimed a tag of its own.
        #expect(html.components(separatedBy: "<header").count - 1 == 1)
        #expect(html.components(separatedBy: "<nav").count - 1 == 1)
        // The siblings that didn't override stay plain spans.
        #expect(html.contains(">One</span>"))
        #expect(html.contains(">Two</span>"))
    }

    @MainActor
    @Test("An empty if-without-else sibling doesn't push a container's tag onto its lone child")
    func emptyOptionalSiblingDoesNotDisplaceContainerTag() {
        // hoistRequests used to treat "exactly one populated child" as proof
        // that a container was a transparent modifier wrapper, but an
        // if-without-else that evaluated false produces exactly that shape
        // too: a real container with a genuine child, plus an empty
        // OptionalView contributing nothing. The tag the author put on the
        // container was hoisted straight past it onto the lone survivor,
        // costing the container its own element and displacing the
        // survivor's derived heading.
        let view = VStack {
            Text("Title").font(.title)
            if false {
                Text("Never shown")
            }
        }
        .htmlTag(.article)
        let html = StaticHTMLRenderer.render(view, title: "Optional sibling").html

        #expect(html.components(separatedBy: "<article").count - 1 == 1)
        // The tag landed on the VStack, so Title is free to become the
        // heading its declared style calls for, rather than being consumed
        // by the container's own tag.
        #expect(html.contains(">Title</h2>"))
    }

    @MainActor
    @Test("A tagged Group wrapping a single view still reaches that view")
    func taggedGroupStillReachesItsSingleChild() {
        // A Group wrapping exactly one child is the transparent-wrapper case
        // the single-child collapse exists for; it must keep working once
        // that collapse is restricted to widgets that only ever had one
        // child in the tree (as opposed to one that merely rendered empty).
        let view = Group {
            Text("Solo")
        }
        .htmlTag(.aside)
        let html = StaticHTMLRenderer.render(view, title: "Tagged group").html

        #expect(html.contains("<aside"))
        #expect(html.contains(">Solo</aside>"))
    }

    @MainActor
    @Test("A container's tag leaves its children's derived headings intact")
    func containerTagDoesNotEatDerivedHeadings() {
        let view = VStack {
            Text("Name").font(.largeTitle)
            Text("Subtitle")
            HStack {
                Text("Link")
            }
            .htmlTag(.nav)
        }
        .htmlTag(.header)
        let html = StaticHTMLRenderer.render(view, title: "Headings").html

        // The heading is derived on the leaf; the container's tag must not
        // land on that leaf and displace it.
        #expect(html.contains(">Name</h1>"))
        #expect(html.components(separatedBy: "<header").count - 1 == 1)
    }

    @MainActor
    @Test("Nested tagged containers each keep their own element")
    func nestedTaggedContainersEachKeepTheirTag() {
        let view = VStack {
            Text("Experience").font(.title)

            VStack {
                Text("Role").font(.title3)
                Text("Detail")
            }
            .htmlTag(.article)

            VStack {
                Text("Other role").font(.title3)
                Text("Detail")
            }
            .htmlTag(.article)
        }
        .htmlTag(.section)
        let html = StaticHTMLRenderer.render(view, title: "Nested").html

        #expect(html.components(separatedBy: "<section").count - 1 == 1)
        #expect(html.components(separatedBy: "<article").count - 1 == 2)
        // The section's own heading keeps the level it derived.
        #expect(html.contains(">Experience</h2>"))
        #expect(html.contains(">Role</h4>"))
    }

    @MainActor
    @Test("An attributes request on a container isn't copied onto every leaf")
    func containerAttributesSurviveAnOverridingChild() {
        let view = VStack {
            Text("One")
            Text("Two").htmlAttributes(["id": "inner"])
        }
        .htmlAttributes(["id": "outer"])
        let html = StaticHTMLRenderer.render(view, title: "Attributes").html

        #expect(html.components(separatedBy: "id=\"outer\"").count - 1 == 1)
        #expect(html.components(separatedBy: "id=\"inner\"").count - 1 == 1)
    }

    @MainActor
    @Test("Raw string tags are validated, and junk is rejected")
    func rejectsInvalidRawStringTags() {
        let valid = StaticHTMLRenderer.render(
            Text("Grouped").htmlTag("hgroup"),
            title: "Raw"
        ).html
        #expect(valid.contains("<hgroup"))

        let invalid = StaticHTMLRenderer.render(
            Text("Grouped").htmlTag("not a tag"),
            title: "Raw"
        ).html
        #expect(!invalid.contains("not a tag"))
        #expect(invalid.contains(">Grouped</span>"))
    }

    @MainActor
    @Test("Author attributes are emitted and escaped")
    func emitsAuthorAttributes() {
        let view = Text("Labelled").htmlAttributes(["aria-label": "A \"quoted\" label"])
        let html = StaticHTMLRenderer.render(view, title: "Attributes").html

        #expect(html.contains("aria-label=\"A &quot;quoted&quot; label\""))
    }

    @MainActor
    @Test("A Color leaf carries an explicit tag and author attributes")
    func colorLeafCapturesHtmlIntent() {
        let view = Color.red
            .htmlTag(.nav)
            .htmlAttributes(["aria-hidden": "true"])
        let html = StaticHTMLRenderer.render(view, title: "Color intent").html

        #expect(html.contains("<nav"))
        #expect(html.contains("aria-hidden=\"true\""))
    }

    @MainActor
    @Test("A tagged void leaf inside a frame takes the frame's size directly")
    func voidLeafInheritsDeclaredFrame() {
        let view = Text("")
            .frame(width: 400, height: 267)
            .htmlTag(.custom("img"))
            .htmlAttributes(["src": "/photo.jpg", "alt": "A photo"])
        let html = StaticHTMLRenderer.render(view, title: "Image with frame").html

        #expect(html.contains("<img"))
        #expect(html.contains("src=\"/photo.jpg\""))
        // The size lands on the img's own class, not just a wrapper's: a
        // wrapper div sizing itself wouldn't stretch a void element, which is
        // replaced content the browser sizes on its own.
        let imgRule = Self.styleRule(forElementContaining: "<img", in: html)
        #expect(imgRule?.contains("width:400px") == true)
        #expect(imgRule?.contains("height:267px") == true)
    }

    @MainActor
    @Test("A flexible frame's min/max constraints become CSS min/max, not a fixed size")
    func flexibleFrameReportsMinMaxConstraints() {
        // Only StrictFrameView (.frame(width:height:)) used to report through
        // describeFrame; FlexibleFrameView (.frame(minWidth:...)) silently
        // dropped its constraints in flow emission — the same
        // declared-intent-inversion bug class StrictFrameView had before
        // describeFrame existed.
        //
        // No .htmlTag() here: a frame wrapping a single child is exactly the
        // shape that gets hoisted onto its child (see task #17), so an
        // explicit tag would land on the Text leaf, not on the frame's own
        // div — the interned stylesheet is checked directly instead, since
        // the frame's declared class exists whichever element ends up
        // wearing the tag.
        let view = Text("Flexible")
            .frame(minWidth: 100, maxWidth: 300, minHeight: 50, maxHeight: 200)
        let html = StaticHTMLRenderer.render(view, title: "Flexible frame").html

        let frameRule = Self.internedRule(containing: "min-width:100px", in: html)
        #expect(frameRule?.contains("min-width:100px") == true)
        #expect(frameRule?.contains("max-width:300px") == true)
        #expect(frameRule?.contains("min-height:50px") == true)
        #expect(frameRule?.contains("max-height:200px") == true)
        // A range isn't a fixed size, so it must not also emit a plain
        // width/height the way a strict frame would.
        #expect(frameRule?.contains("{width:") != true && frameRule?.contains(";width:") != true)
        #expect(frameRule?.contains("{height:") != true && frameRule?.contains(";height:") != true)
    }

    @MainActor
    @Test("An unconstrained axis on a flexible frame emits no min/max for that axis")
    func flexibleFrameOmitsUnconstrainedAxis() {
        let view = Text("Flexible")
            .frame(minWidth: 100)
        let html = StaticHTMLRenderer.render(view, title: "Partially flexible frame").html

        let frameRule = Self.internedRule(containing: "min-width:100px", in: html)
        #expect(frameRule?.contains("min-width:100px") == true)
        #expect(frameRule?.contains("max-width:") != true)
        #expect(frameRule?.contains("min-height:") != true)
        #expect(frameRule?.contains("max-height:") != true)
    }

    @MainActor
    @Test("A tagged void leaf with no frame gets no size CSS")
    func voidLeafWithoutFrameStaysUnsized() {
        let view = Text("")
            .htmlTag(.custom("img"))
            .htmlAttributes(["src": "/photo.jpg", "alt": "A photo"])
        let html = StaticHTMLRenderer.render(view, title: "Image without frame").html

        #expect(html.contains("<img"))
        #expect(html.contains("src=\"/photo.jpg\""))
        // No frame was declared, so the browser sizes the img from the
        // fetched file rather than from a pinned box. Checking for "height:"
        // as a bare substring would false-positive on "line-height:", which
        // the TextView carrier still sets, so the declaration boundary
        // (preceded by "{" or ";") has to be part of the match.
        let imgRule = Self.styleRule(forElementContaining: "<img", in: html)
        #expect(imgRule?.contains("{width:") != true && imgRule?.contains(";width:") != true)
        #expect(imgRule?.contains("{height:") != true && imgRule?.contains(";height:") != true)
    }

    /// Finds the interned style rule for the element whose opening tag
    /// contains `marker`, by reading its `class` attribute out of the body
    /// and looking up the matching `.scui-N { … }` rule in the stylesheet.
    private static func styleRule(forElementContaining marker: String, in html: String) -> String? {
        guard
            let elementLine = html.split(separator: "\n").first(where: { $0.contains(marker) }),
            let classRange = elementLine.range(of: "class=\"")
        else {
            return nil
        }
        let afterClass = elementLine[classRange.upperBound...]
        guard let closingQuote = afterClass.firstIndex(of: "\"") else {
            return nil
        }
        let className = String(afterClass[..<closingQuote])
        return html.split(separator: "\n").first { $0.contains(".\(className) {") }.map(String.init)
    }

    /// Finds the interned style rule containing `marker`, without going
    /// through an element's `class` attribute first.
    ///
    /// Useful when the element carrying the rule isn't the one under test —
    /// hoisting (see task #17) can move an explicit tag off a wrapper and
    /// onto its single child, leaving the wrapper's own class undiscoverable
    /// from its tag alone.
    private static func internedRule(containing marker: String, in html: String) -> String? {
        html.split(separator: "\n").first { $0.contains(marker) }.map(String.init)
    }

    @MainActor
    @Test("Authors can't overwrite the attributes the backend owns")
    func ignoresReservedAuthorAttributes() {
        let view = Text("Styled").htmlAttributes([
            "style": "color:red",
            "class": "mine",
            "data-scui": "Fake",
            "id": "kept",
        ])
        let html = StaticHTMLRenderer.render(view, title: "Reserved").html

        #expect(!html.contains("color:red"))
        #expect(!html.contains("class=\"mine\""))
        #expect(!html.contains("data-scui=\"Fake\""))
        // Attributes the backend doesn't own still come through.
        #expect(html.contains("id=\"kept\""))
    }

    @MainActor
    @Test("Text content is escaped rather than emitted as markup")
    func escapesTextContent() {
        let view = Text("<script>alert('x')</script>")
        let html = StaticHTMLRenderer.render(view, title: "Escaping").html

        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
    }

    @MainActor
    @Test("Layout doesn't depend on the color scheme")
    func geometryIsColorSchemeInvariant() {
        let view = VStack {
            Text("Title").font(.largeTitle)
            Text("Body text that has to wrap somewhere along the way")
            Button("Press") {}
            Color.blue.frame(width: 100, height: 10)
        }
        let result = StaticHTMLRenderer.render(view, title: "Invariance")

        #expect(result.geometryMismatches.isEmpty)
    }

    @MainActor
    @Test("Foreground colors resolve differently per scheme")
    func emitsPerSchemeForegroundColors() {
        let html = StaticHTMLRenderer.render(Text("Adaptive"), title: "Colors").html

        // The default foreground is black in light mode and white in dark, so
        // it has to become a custom property rather than a literal.
        #expect(html.contains("@media (prefers-color-scheme: dark)"))
        #expect(html.contains("color-scheme: light dark"))
        #expect(html.contains("color:var(--scui-c0)"))
    }

    @MainActor
    @Test("Styling goes through classes, never inline style attributes")
    func emitsNoInlineStyles() {
        let view = VStack {
            Text("One")
            Text("Two")
        }
        let html = StaticHTMLRenderer.render(view, title: "No inline styles").html

        #expect(!html.contains("<span style="))
        #expect(!html.contains("<div style="))
        #expect(html.contains("class=\"scui-"))
    }

    @MainActor
    @Test("Widgets keep the view type name the core stamps on them")
    func retainsViewTypeNames() {
        let html = StaticHTMLRenderer.render(Text("Tagged"), title: "Tags").html

        #expect(html.contains("data-scui=\"Text\""))
    }

    @MainActor
    @Test("Buttons become links carrying a button role")
    func emitsButtonsAsLinks() {
        let html = StaticHTMLRenderer.render(Button("Press") {}, title: "Buttons").html

        #expect(html.contains("<a "))
        #expect(html.contains("role=\"button\""))
        #expect(html.contains("href=\"#\""))
        #expect(html.contains(">Press</a>"))
    }

    @MainActor
    @Test("Text that wraps is allocated every line it needs")
    func allocatesHeightForWrappedText() {
        // Long enough to need more than one line at this width. A finite height
        // proposal would make Text truncate to what fits instead, and the
        // browser would then wrap the full string outside the emitted box.
        let long = String(repeating: "word ", count: 60)
        let lineHeight = Int(
            EnvironmentValues(backend: StaticHTMLBackend()).resolvedFont.lineHeight
        )

        let result = StaticHTMLRenderer.render(
            Text(long),
            title: "Wrapping",
            size: SIMD2(400, 50)
        )

        #expect(result.size.y > lineHeight)
    }

    @MainActor
    @Test("A document grows past its proposed height rather than truncating")
    func documentHeightIsAnOutcomeNotAConstraint() {
        let view = VStack {
            ForEach(0..<20, id: \.self) { _ in
                Text("A line of body text.")
            }
        }

        let result = StaticHTMLRenderer.render(
            view,
            title: "Overflow",
            size: SIMD2(400, 40)
        )

        #expect(result.size.y > 40)
    }

    @MainActor
    @Test("Flowing text is neither clipped nor pinned to its measured box")
    func doesNotClipOrPinFlowingText() {
        let long = String(repeating: "word ", count: 60)
        let html = StaticHTMLRenderer.render(
            Text(long),
            title: "Flow",
            size: SIMD2(400, 200)
        ).html

        // Build-host measurement is an estimate. Clipping it to the estimate
        // would cut off prose the browser wrapped onto one more line, and a
        // fixed width would stop it reflowing at all.
        #expect(!html.contains("overflow:hidden"))
        #expect(!html.contains("position:absolute"))
        #expect(!html.contains("width:400px"))
    }

    @MainActor
    @Test("The document reflows rather than fixing itself to the layout width")
    func rootIsAMaximumWidthNotAFixedOne() {
        let html = StaticHTMLRenderer.render(
            Text("Body"),
            title: "Reflow",
            size: SIMD2(800, 600)
        ).html

        #expect(html.contains("#root { max-width: 800px; }"))
        // A committed height would stop the content deciding how tall it is.
        #expect(!html.contains("height: 600px"))
    }

    @MainActor
    @Test("Stacks become flex containers carrying their spacing and alignment")
    func emitsStacksAsFlexContainers() {
        let vertical = StaticHTMLRenderer.render(
            VStack(alignment: .leading, spacing: 12) {
                Text("One")
                Text("Two")
            },
            title: "VStack"
        ).html

        #expect(vertical.contains("flex-direction:column"))
        #expect(vertical.contains("gap:12px"))
        #expect(vertical.contains("align-items:flex-start"))

        let horizontal = StaticHTMLRenderer.render(
            HStack(spacing: 4) {
                Text("One")
                Text("Two")
            },
            title: "HStack"
        ).html

        #expect(horizontal.contains("flex-direction:row"))
        #expect(horizontal.contains("gap:4px"))
    }

    @MainActor
    @Test("Padding becomes CSS padding rather than an offset child")
    func emitsPaddingAsCSSPadding() {
        let html = StaticHTMLRenderer.render(
            Text("Inset").padding(24),
            title: "Padding"
        ).html

        #expect(html.contains("padding:24px 24px 24px 24px"))
        #expect(!html.contains("position:absolute"))
    }

    @MainActor
    @Test("A width the author declared is kept, and the text inside it still wraps")
    func keepsDeclaredFrameWidth() {
        let html = StaticHTMLRenderer.render(
            Text("Text long enough that it has to wrap inside the frame it was given.")
                .frame(width: 300),
            title: "Frame"
        ).html

        // A declared frame is the only way an author pins geometry, so it's
        // the only thing that survives into output that otherwise reflows.
        #expect(html.contains("width:300px"))
        // The frame sets the measure; it doesn't stop the text flowing inside
        // it, and its leftover space must not be read back as padding.
        #expect(!html.contains("position:absolute"))
        #expect(!html.contains("padding"))
    }

    @MainActor
    @Test("Only overlapping children fall back to absolute positioning")
    func onlyOverlappingChildrenAreAbsolutelyPositioned() {
        let overlapping = StaticHTMLRenderer.render(
            ZStack {
                Color.blue.frame(width: 200, height: 60)
                Text("Overlaid")
            },
            title: "ZStack"
        ).html

        // Flow has no rule that puts one element on top of another.
        #expect(overlapping.contains("position:absolute"))
        #expect(overlapping.contains("position:relative"))

        // Children that merely sit side by side reflow instead.
        let sideBySide = StaticHTMLRenderer.render(
            HStack {
                Text("One")
                Text("Two")
            },
            title: "Flow"
        ).html
        #expect(!sideBySide.contains("position:absolute"))
    }

    @MainActor
    @Test("Content with no intrinsic size keeps the size it was given")
    func keepsExplicitSizeForContentWithoutIntrinsicSize() {
        let html = StaticHTMLRenderer.render(
            Color.blue.frame(width: 320, height: 4),
            title: "Frame"
        ).html

        // A rectangle has nothing inside it to derive a height from, so
        // dropping its committed size would collapse it entirely.
        #expect(html.contains("min-width:320px"))
        #expect(html.contains("min-height:4px"))
    }

    @MainActor
    @Test("Stacked text is laid out without any two boxes overlapping")
    func stackedTextBoxesDoNotOverlap() {
        let view = VStack(alignment: .leading, spacing: 5) {
            Text(String(repeating: "wrapping text ", count: 12))
            Text(String(repeating: "more wrapping text ", count: 12))
            Text("Short")
        }

        let backend = StaticHTMLBackend()
        let window = backend.createWindow(withDefaultSize: SIMD2(300, 100), id: "test")
        let environment = EnvironmentValues(backend: backend).with(\.window, window)
        let node = ViewGraphNode(for: view, backend: backend, environment: environment)
        _ = node.computeLayout(
            proposedSize: ProposedViewSize(300, nil),
            environment: environment
        )
        _ = node.commit()

        // Walk the committed tree collecting absolute rectangles, then check
        // that no two leaves share any area.
        var rectangles: [(origin: SIMD2<Int>, size: SIMD2<Int>)] = []
        func collect(_ widget: StaticHTMLBackend.Widget, at origin: SIMD2<Int>) {
            if let container = widget as? StaticHTMLBackend.Container {
                for (child, position) in container.children {
                    collect(child, at: origin &+ position)
                }
            } else {
                rectangles.append((origin, widget.size))
            }
        }
        collect(node.widget, at: .zero)

        #expect(rectangles.count == 3)
        for first in rectangles.indices {
            for second in rectangles.indices where second > first {
                let a = rectangles[first]
                let b = rectangles[second]
                let verticalOverlap =
                    min(a.origin.y + a.size.y, b.origin.y + b.size.y)
                        - max(a.origin.y, b.origin.y)
                let horizontalOverlap =
                    min(a.origin.x + a.size.x, b.origin.x + b.size.x)
                        - max(a.origin.x, b.origin.x)
                #expect(verticalOverlap <= 0 || horizontalOverlap <= 0)
            }
        }
    }
}
