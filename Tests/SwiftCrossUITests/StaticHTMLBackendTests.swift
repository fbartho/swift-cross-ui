import Testing

import Foundation
import ImageFormats
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
        let html = StaticHTMLRenderer.render(view, context: "Specificity").html

        // The reset selector carries zero specificity of its own, so it
        // never wins a cascade tie against a heading's interned class.
        #expect(html.contains(":where(#root h1, #root h2"))
        #expect(!html.contains("#root :where(h1"))

        // The size itself now rides a custom property (see ``TypeScale``), so
        // what has to survive the reset is the reference — if the reset won
        // this tie, the heading would compute to the UA default no matter
        // what the property resolves to.
        let headingRule = Self.styleRule(forElementContaining: "<h1", in: html)
        #expect(headingRule?.contains("font-size:var(--scui-fs-large-title)") == true)
        #expect(html.contains("--scui-fs-large-title: 34px;"))
    }

    @MainActor
    @Test("A .background() Color sibling doesn't displace an ancestor's tag")
    func backgroundColorSiblingDoesNotDisplaceAncestorTag() {
        // A Color leaf has to carry pendingTagRequest. A leaf reporting no
        // request at all reads as "not covered by anything", and one
        // uncovered child rules out every candidate tag for the whole
        // subtree (see deepestCommonRequest) — so a .background(Color(...)),
        // which introduces exactly one such sibling, would otherwise knock
        // the tag off the container it was applied to and take any derived
        // headings with it.
        let view = VStack {
            Text("Title").font(.largeTitle)
            Text("Code block").background(Color.gray)
        }
        .htmlTag(.article)
        let html = StaticHTMLRenderer.render(view, context: "Background sibling").html

        #expect(html.contains("<article"))
        #expect(html.contains("<h1"))
        #expect(html.contains(">Title</h1>"))
    }

    @MainActor
    @Test(
        "A .background() backdrop stretches to the foreground's box instead of pinning to committed px"
    )
    func backgroundBackdropStretchesToForegroundBox() {
        // .background()'s two-child pair (backdrop, foreground) must not go
        // through the generic overlap-pin path, which bakes FIXED px
        // width/height from the build-host committed size onto every child
        // and so silently overrides a declared .frame(maxWidth:) on the
        // foreground (max-width and width land on the same element, and a
        // fixed width always wins). The isBackgroundLayering pair is
        // special-cased instead: the foreground keeps flow sizing, and with
        // it its own declared constraints, while the backdrop tracks
        // whatever box that turns out to be via inset:0.
        let html = StaticHTMLRenderer.render(
            Text("Panel").frame(maxWidth: 400).background(Color.gray),
            context: "Background stretch",
            size: SIMD2(1400, 900)
        ).html

        let wrapperRule = Self.internedRule(containing: "position:relative", in: html)
        #expect(wrapperRule?.contains("width:") != true)
        #expect(wrapperRule?.contains("height:") != true)

        let backdropRule = Self.internedRule(containing: "background-color:", in: html)
        #expect(backdropRule?.contains("inset:0") == true)
        #expect(backdropRule?.contains("position:absolute") == true)
        #expect(backdropRule?.contains("width:") != true)
        #expect(backdropRule?.contains("height:") != true)

        // The foreground's own declared constraint has to survive untouched.
        // A fixed `width:` accompanying the `max-width:` on the same rule
        // (the one the FlexibleFrameView wrapper emits for .frame(maxWidth:))
        // would win the cascade and defeat it. Matching on ` width:` rather
        // than `width:` is deliberate — the latter also matches inside
        // "max-width:".
        let foregroundRule = Self.internedRule(containing: "max-width:400px", in: html)
        #expect(foregroundRule?.contains("max-width:400px") == true)
        #expect(foregroundRule?.contains(" width:") != true)
    }

    @MainActor
    @Test("A .background() backdrop paints behind the foreground, not over it")
    func backgroundBackdropPaintsBehindForeground() {
        // The backdrop is positioned (inset:0) while the foreground stays in
        // normal flow, and a positioned element paints above unpositioned
        // in-flow siblings regardless of tree order (CSS 2.1 Appendix E,
        // step 8 vs steps 4 and 7). Geometry assertions alone can all pass
        // on a page that renders blank, so paint order is asserted directly.
        //
        // Browser-verified with elementFromPoint over the text (see
        // Scripts/check-paint-order.mjs): the hit is the Text span, not the
        // backdrop Color div.
        let html = StaticHTMLRenderer.render(
            Text("Panel").background(Color.gray),
            context: "Background paint order",
            size: SIMD2(1400, 900)
        ).html

        let backdropRule = Self.internedRule(containing: "background-color:", in: html)
        #expect(backdropRule?.contains("z-index:-1") == true)

        // Without a stacking context on the wrapper, z-index:-1 escapes past
        // this subtree and lands behind the ancestors' backgrounds instead
        // of just behind the foreground.
        let wrapperRule = Self.internedRule(containing: "position:relative", in: html)
        #expect(wrapperRule?.contains("isolation:isolate") == true)
    }

    @MainActor
    @Test("A ZStack's top layer still paints last, since both layers stay positioned")
    func zStackTopLayerPaintsLast() {
        // The overlap-pin path (both children position:absolute, no z-index)
        // is separate from the backdrop-layering path: equal-level
        // positioned siblings paint in tree order, so the last child wins.
        // Asserted so a future z-index added to that path can't silently
        // invert it.
        let html = StaticHTMLRenderer.render(
            ZStack {
                Color.gray.frame(width: 300, height: 100)
                Text("Top layer")
            },
            context: "ZStack paint order",
            size: SIMD2(1400, 900)
        ).html

        let backdropIndex = html.range(of: "data-scui=\"Color\"")?.lowerBound
        let textIndex = html.range(of: "data-scui=\"Text\"")?.lowerBound
        #expect(backdropIndex != nil)
        #expect(textIndex != nil)
        if let backdropIndex, let textIndex {
            #expect(backdropIndex < textIndex)
        }
        #expect(Self.internedRule(containing: "background-color:", in: html)?
            .contains("z-index") != true)
    }

    @MainActor
    @Test("A view using .task doesn't crash the one-shot render")
    func taskModifierDoesNotCrash() {
        // .task routes through .onChange(of:initial:) internally
        // (TaskModifier.body), which persists state via @State. Every
        // @State property makes ViewGraphNode.init register an observer
        // through Publisher.observeAsUIUpdater, which hops to a background
        // queue before calling back into the backend - so this exercises
        // the same MainActor executor assumption regardless of whether
        // the task body itself ever runs.
        let view = Text("Has an async task hook").task {}
        let html = StaticHTMLRenderer.render(view, context: "Task").html

        #expect(html.contains("Has an async task hook"))
    }

    @MainActor
    @Test("A view using .onChange doesn't crash the one-shot render")
    func onChangeModifierDoesNotCrash() {
        let view = Text("Has an onChange hook").onChange(of: 1) {}
        let html = StaticHTMLRenderer.render(view, context: "OnChange").html

        #expect(html.contains("Has an onChange hook"))
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
        let html = StaticHTMLRenderer.render(view, context: "Headings").html

        #expect(html.contains(">Title</h1>"))
        #expect(html.contains(">Section</h2>"))
        #expect(html.contains(">Body</span>"))
    }

    @MainActor
    @Test("An explicit tag overrides a derived heading")
    func explicitTagOverridesDerivedHeading() {
        let view = Text("Title").font(.largeTitle).htmlTag(.p)
        let html = StaticHTMLRenderer.render(view, context: "Override").html

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
        let html = StaticHTMLRenderer.render(view, context: "Nav").html

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
        let html = StaticHTMLRenderer.render(view, context: "Mixed").html

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
        // hoistRequests must not treat "exactly one populated child" as proof
        // that a container is a transparent modifier wrapper: an
        // if-without-else that evaluates false produces exactly that shape
        // too — a real container with a genuine child, plus an empty
        // OptionalView contributing nothing. Hoisting there would carry the
        // author's tag past the container onto the lone survivor, costing
        // the container its own element and displacing the survivor's
        // derived heading.
        let view = VStack {
            Text("Title").font(.title)
            if false {
                Text("Never shown")
            }
        }
        .htmlTag(.article)
        let html = StaticHTMLRenderer.render(view, context: "Optional sibling").html

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
        let html = StaticHTMLRenderer.render(view, context: "Tagged group").html

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
        let html = StaticHTMLRenderer.render(view, context: "Headings").html

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
        let html = StaticHTMLRenderer.render(view, context: "Nested").html

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
        let html = StaticHTMLRenderer.render(view, context: "Attributes").html

        #expect(html.components(separatedBy: "id=\"outer\"").count - 1 == 1)
        #expect(html.components(separatedBy: "id=\"inner\"").count - 1 == 1)
    }

    // MARK: - Stacked .htmlAttributes on the SAME view merge

    @MainActor
    @Test("Two stacked .htmlAttributes calls on one view both reach the element")
    func stackedAttributesOnOneViewMerge() {
        let view = Text("Both").htmlAttributes(["data-outer": "o"]).htmlAttributes([
            "data-inner": "i"
        ])
        let html = StaticHTMLRenderer.render(view, context: "Merge").html

        #expect(html.contains("data-outer=\"o\""))
        #expect(html.contains("data-inner=\"i\""))
    }

    @MainActor
    @Test("On a conflicting key, the innermost (closer to the content) call wins")
    func stackedAttributesConflictingKeyInnermostWins() {
        // The SECOND .htmlAttributes call is applied outside the first —
        // transformEnvironment wraps outer-then-inner as the view builds —
        // so the first call (closer to Text) is the innermost in the
        // resolved chain and should win the "id" conflict.
        let view = Text("Conflict")
            .htmlAttributes(["id": "closer-to-content"])
            .htmlAttributes(["id": "farther-from-content"])
        let html = StaticHTMLRenderer.render(view, context: "Merge").html

        #expect(html.contains("id=\"closer-to-content\""))
        #expect(!html.contains("id=\"farther-from-content\""))
    }

    @MainActor
    @Test("Reserved keys still strip after merging stacked .htmlAttributes calls")
    func stackedAttributesReservedKeysStillStripped() {
        let view = Text("Guarded")
            .htmlAttributes(["style": "color:red", "data-real": "kept-inner"])
            .htmlAttributes(["class": "mine", "data-other": "kept-outer"])
        let html = StaticHTMLRenderer.render(view, context: "Merge").html

        #expect(!html.contains("color:red"))
        #expect(!html.contains("class=\"mine\""))
        #expect(html.contains("data-real=\"kept-inner\""))
        #expect(html.contains("data-other=\"kept-outer\""))
    }

    @MainActor
    @Test("A three-deep stack of .htmlAttributes calls resolves the full chain")
    func threeDeepAttributesStackResolvesFully() {
        // Mirrors GeometrySelector's realistic composition: an outer marker
        // (e.g. a structural-selector's data-gsel), a middle layer an author
        // or another component added, and content-level attributes closest
        // to the leaf itself — all three must reach the element.
        let view = Text("Layered")
            .htmlAttributes(["data-content": "innermost"])
            .htmlAttributes(["data-component": "middle"])
            .htmlAttributes(["data-marker": "outermost"])
        let html = StaticHTMLRenderer.render(view, context: "Merge").html

        #expect(html.contains("data-content=\"innermost\""))
        #expect(html.contains("data-component=\"middle\""))
        #expect(html.contains("data-marker=\"outermost\""))
    }

    @MainActor
    @Test("Raw string tags are validated, and junk is rejected")
    func rejectsInvalidRawStringTags() {
        let valid = StaticHTMLRenderer.render(
            Text("Grouped").htmlTag("hgroup"),
            context: "Raw"
        ).html
        #expect(valid.contains("<hgroup"))

        let invalid = StaticHTMLRenderer.render(
            Text("Grouped").htmlTag("not a tag"),
            context: "Raw"
        ).html
        #expect(!invalid.contains("not a tag"))
        #expect(invalid.contains(">Grouped</span>"))
    }

    @MainActor
    @Test("Author attributes are emitted and escaped")
    func emitsAuthorAttributes() {
        let view = Text("Labelled").htmlAttributes(["aria-label": "A \"quoted\" label"])
        let html = StaticHTMLRenderer.render(view, context: "Attributes").html

        #expect(html.contains("aria-label=\"A &quot;quoted&quot; label\""))
    }

    @MainActor
    @Test("A Color leaf carries an explicit tag and author attributes")
    func colorLeafCapturesHtmlIntent() {
        let view = Color.red
            .htmlTag(.nav)
            .htmlAttributes(["aria-hidden": "true"])
        let html = StaticHTMLRenderer.render(view, context: "Color intent").html

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
        let html = StaticHTMLRenderer.render(view, context: "Image with frame").html

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
        // FlexibleFrameView (.frame(minWidth:…)) has to report through
        // describeFrame just as StrictFrameView (.frame(width:height:))
        // does; otherwise its constraints drop silently in flow emission.
        //
        // No .htmlTag() here: a frame wrapping a single child is exactly the
        // shape that gets hoisted onto its child, so an explicit tag would
        // land on the Text leaf rather than the frame's own div. The
        // interned stylesheet is checked directly instead, since the frame's
        // declared class exists whichever element ends up wearing the tag.
        let view = Text("Flexible")
            .frame(minWidth: 100, maxWidth: 300, minHeight: 50, maxHeight: 200)
        let html = StaticHTMLRenderer.render(view, context: "Flexible frame").html

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
        let html = StaticHTMLRenderer.render(view, context: "Partially flexible frame").html

        let frameRule = Self.internedRule(containing: "min-width:100px", in: html)
        #expect(frameRule?.contains("min-width:100px") == true)
        #expect(frameRule?.contains("max-width:") != true)
        #expect(frameRule?.contains("min-height:") != true)
        #expect(frameRule?.contains("max-height:") != true)
    }

    @MainActor
    @Test("An infinite maxWidth emits stretch CSS instead of a max-width declaration")
    func infiniteMaxWidthEmitsStretchNotMaxWidth() {
        // .frame(maxWidth: .infinity) is the SwiftUI stretch idiom ("greedy,
        // fill the container"), not "no opinion" — it must diverge from both
        // a finite maxWidth (which becomes a CSS max-width ceiling) and from
        // no frame at all (which emits nothing and content-sizes). See
        // ``HTMLEmitter/applyInfiniteStretch(in:)``.
        let finite = StaticHTMLRenderer.render(
            Text("Panel").frame(maxWidth: 400),
            context: "Finite maxWidth"
        ).html
        let infinite = StaticHTMLRenderer.render(
            Text("Panel").frame(maxWidth: .infinity),
            context: "Infinite maxWidth"
        ).html
        let unframed = StaticHTMLRenderer.render(
            Text("Panel"),
            context: "No frame"
        ).html

        let finiteRule = Self.internedRule(containing: "max-width:400px", in: finite)
        #expect(finiteRule?.contains("max-width:400px") == true)
        #expect(finiteRule?.contains("align-self:stretch") != true)

        let infiniteRule = Self.internedRule(containing: "align-self:stretch", in: infinite)
        #expect(infiniteRule?.contains("align-self:stretch") == true)
        #expect(infiniteRule?.contains("flex-grow:1") == true)
        #expect(infinite.contains("max-width:") == false)

        #expect(!unframed.contains("align-self:stretch"))
        #expect(!unframed.contains("flex-grow:"))
    }

    @MainActor
    @Test("An infinite maxWidth child fills a wider VStack via align-self:stretch")
    func infiniteMaxWidthStretchesAcrossVStackCrossAxis() {
        // Width is the VStack's cross axis, where align-items defaults to
        // flex-start (shrink-to-fit) — the exact case where an unstyled
        // stretch child would silently content-size instead of filling the
        // column, which is what this test guards against regressing.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .leading) {
                Text("Narrow")
                Text("Wide").frame(maxWidth: .infinity)
            },
            context: "Stretch child"
        ).html

        #expect(html.contains("align-items:flex-start"))
        let stretchRule = Self.internedRule(containing: "align-self:stretch", in: html)
        #expect(stretchRule?.contains("align-self:stretch") == true)
    }

    @MainActor
    @Test("A tagged void leaf with no frame gets no size CSS")
    func voidLeafWithoutFrameStaysUnsized() {
        let view = Text("")
            .htmlTag(.custom("img"))
            .htmlAttributes(["src": "/photo.jpg", "alt": "A photo"])
        let html = StaticHTMLRenderer.render(view, context: "Image without frame").html

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

    @MainActor
    @Test("An Image view emits a real img with its pixel data inlined as a PNG data URL")
    func imageViewEmitsInlinedPNG() {
        // Distinct from the escape-hatch tests above: those presume an
        // author-written <img src> already exists via .htmlTag/.htmlAttributes.
        // This exercises the actual Image(_:) view, which needs its own
        // HTMLEmitter case — without one it falls through to an empty div
        // and the image content is lost entirely.
        let source = ImageFormats.Image<RGBA>(
            width: 2,
            height: 2,
            pixels: [
                RGBA(255, 0, 0, 255),
                RGBA(0, 255, 0, 255),
                RGBA(0, 0, 255, 255),
                RGBA(255, 255, 255, 255),
            ]
        )
        let html = StaticHTMLRenderer.render(
            SwiftCrossUI.Image(source),
            context: "Image view"
        ).html

        #expect(html.contains("<img"))
        #expect(html.contains("src=\"data:image/png;base64,"))

        // The data URL round-trips to the exact source bytes rather than a
        // placeholder or a re-encoded approximation — decode it and check
        // the magic bytes and declared dimensions rather than trusting the
        // src attribute's mere presence.
        guard
            let srcRange = html.range(of: "src=\"data:image/png;base64,"),
            let closingQuote = html[srcRange.upperBound...].firstIndex(of: "\"")
        else {
            Issue.record("No data URL found in emitted <img>")
            return
        }
        let base64 = String(html[srcRange.upperBound..<closingQuote])
        let pngBytes = try? Data(base64Encoded: base64).map { [UInt8]($0) }
        #expect(pngBytes?.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) == true)

        let decoded = pngBytes.flatMap { try? ImageFormats.Image<RGBA>.loadPNG(from: $0) }
        #expect(decoded?.width == 2)
        #expect(decoded?.height == 2)
        #expect(decoded?.bytes == source.bytes)
    }

    @MainActor
    @Test("An Image view without an author-supplied alt gets alt=\"\", not a missing attribute")
    func imageViewDefaultsToEmptyAlt() {
        let source = ImageFormats.Image<RGBA>(
            width: 1,
            height: 1,
            pixels: [RGBA(0, 0, 0, 255)]
        )
        let html = StaticHTMLRenderer.render(SwiftCrossUI.Image(source), context: "No alt").html

        // No accessibilityLabel modifier exists in SwiftCrossUI to source
        // this from, so an explicit empty alt — marking the image
        // decorative — is the honest default, not an omitted attribute a
        // screen reader would fall back to reading the src URL for.
        #expect(html.contains("alt=\"\""))
    }

    @MainActor
    @Test("An author-supplied alt on an Image view reaches the emitted img")
    func imageViewHonorsAuthorSuppliedAlt() {
        let source = ImageFormats.Image<RGBA>(
            width: 1,
            height: 1,
            pixels: [RGBA(0, 0, 0, 255)]
        )
        let html = StaticHTMLRenderer.render(
            SwiftCrossUI.Image(source).htmlAttributes(["alt": "A black square"]),
            context: "Explicit alt"
        ).html

        #expect(html.contains("alt=\"A black square\""))
        #expect(!html.contains("alt=\"\""))
    }

    @MainActor
    @Test("An Image view's committed layout size becomes its img width/height")
    func imageViewSizesFromCommittedLayout() {
        let source = ImageFormats.Image<RGBA>(
            width: 400,
            height: 300,
            pixels: [RGBA](repeating: RGBA(128, 128, 128, 255), count: 400 * 300)
        )
        let html = StaticHTMLRenderer.render(
            SwiftCrossUI.Image(source).resizable().frame(width: 200, height: 150),
            context: "Resized image"
        ).html

        let imgRule = Self.styleRule(forElementContaining: "<img", in: html)
        #expect(imgRule?.contains("width:200px") == true)
        #expect(imgRule?.contains("height:150px") == true)
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
    /// Useful when the element carrying the rule isn't the one under test:
    /// hoisting can move an explicit tag off a wrapper and onto its single
    /// child, leaving the wrapper's own class undiscoverable from its tag
    /// alone.
    private static func internedRule(containing marker: String, in html: String) -> String? {
        html.split(separator: "\n").first { $0.contains(marker) }.map(String.init)
    }

    /// Mutable storage backing a ``box(_:)`` binding.
    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// A binding backed by a mutable box, so controls that require one can be
    /// constructed for a one-shot render without an owning `@State`.
    private static func box<Value>(_ initial: Value) -> Binding<Value> {
        let storage = Box(initial)
        return Binding(get: { storage.value }, set: { storage.value = $0 })
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
        let html = StaticHTMLRenderer.render(view, context: "Reserved").html

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
        let html = StaticHTMLRenderer.render(view, context: "Escaping").html

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
        let result = StaticHTMLRenderer.render(view, context: "Invariance")

        #expect(result.geometryMismatches.isEmpty)
    }

    @MainActor
    @Test("Foreground colors resolve differently per scheme")
    func emitsPerSchemeForegroundColors() {
        let html = StaticHTMLRenderer.render(Text("Adaptive"), context: "Colors").html

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
        let html = StaticHTMLRenderer.render(view, context: "No inline styles").html

        #expect(!html.contains("<span style="))
        #expect(!html.contains("<div style="))
        #expect(html.contains("class=\"scui-"))
    }

    @MainActor
    @Test("Widgets keep the view type name the core stamps on them")
    func retainsViewTypeNames() {
        let html = StaticHTMLRenderer.render(Text("Tagged"), context: "Tags").html

        #expect(html.contains("data-scui=\"Text\""))
    }

    @MainActor
    @Test("An action-only button loads disabled and marked for enlivening")
    func emitsActionOnlyButtonAsDisabledButton() {
        // Tier-activation principle: a click action has nothing pure
        // HTML/CSS can resolve, so the button loads inert — a real
        // <button disabled>, never an <a role="button" href="#">, which
        // would look reachable to a keyboard, crawler, or assistive
        // technology exactly like a working control.
        let html = StaticHTMLRenderer.render(Button("Press") {}, context: "Buttons").html

        #expect(html.contains("<button "))
        #expect(html.contains("type=\"button\""))
        #expect(html.contains("disabled=\"disabled\""))
        #expect(html.contains("data-scui-enliven=\"js\""))
        #expect(html.contains(">Press</button>"))
        #expect(!html.contains("<a "))
        #expect(!html.contains("role=\"button\""))
    }

    @MainActor
    @Test("An href-only button emits a live anchor, never disabled, no role=button needed")
    func emitsHrefOnlyButtonAsLiveLink() {
        // href-only row of the emission matrix: an href is fully resolvable
        // in pure HTML, so this row is live at the floor — no disabled, no
        // role="button" (a real link doesn't need one). It still carries
        // data-scui-enliven: Button.init's action defaults to an empty
        // closure, so nothing distinguishes "href-only" from "href+action"
        // at this layer (see the ambiguity-resolution comment on the Button
        // case in HTMLEmitter) — nothing about that marker's presence makes
        // this row any less live, since <a> has no disabled attribute to
        // gate on it in the first place.
        let html = StaticHTMLRenderer.render(
            Button("Go") {}.href("/docs"),
            context: "Href-only button"
        ).html

        #expect(html.contains("<a "))
        #expect(html.contains("href=\"/docs\""))
        #expect(html.contains(">Go</a>"))
        #expect(!html.contains("disabled=\"disabled\""))
        #expect(!html.contains("aria-disabled"))
        #expect(!html.contains("role=\"button\""))
    }

    @MainActor
    @Test("An href+action button stays a live anchor, marked for enlivening, never disabled")
    func emitsHrefAndActionButtonAsLiveEnlivenedLink() {
        // href+action row: legal coexistence (Frederic, 2026-08-01). The
        // link half is pure-HTML-resolvable, so the emitted <a href> stays
        // alive — never disabled, <a> has no disabled attribute anyway —
        // while the enliven marker tells a later tier to attach the click
        // handler under the modified-click contract documented at the
        // Button case in HTMLEmitter.
        let html = StaticHTMLRenderer.render(
            Button("Track & go") { }.href("/docs"),
            context: "Href+action button"
        ).html

        #expect(html.contains("<a "))
        #expect(html.contains("href=\"/docs\""))
        #expect(html.contains("data-scui-enliven=\"js\""))
        #expect(!html.contains("disabled=\"disabled\""))
        #expect(!html.contains("aria-disabled"))
    }

    @MainActor
    @Test("A disabled button carries disabled semantics and no activatable href")
    func disabledButtonCarriesDisabledSemantics() {
        // Before this fix, mod-disabled was a complete no-op: the emitted
        // `<a href="#" role="button">` was indistinguishable from an enabled
        // button, which is actively misleading rather than merely
        // incomplete (sweep G3). `.disabled(true)` is a hard author
        // override that outranks the tier-activation floor: an href-only
        // Button explicitly disabled still loses its href, since the author
        // said this control shouldn't respond regardless of tier.
        let html = StaticHTMLRenderer.render(
            Button("Disabled action") {}.disabled(true),
            context: "Disabled button"
        ).html

        #expect(html.contains("aria-disabled=\"true\""))
        #expect(html.contains("tabindex=\"-1\""))
        #expect(!html.contains("href="))
    }

    @MainActor
    @Test("A disabled href-only button loses its href even though href is otherwise live")
    func disabledHrefButtonLosesHref() {
        let html = StaticHTMLRenderer.render(
            Button("Disabled link") {}.href("/docs").disabled(true),
            context: "Disabled href button"
        ).html

        #expect(html.contains("aria-disabled=\"true\""))
        #expect(html.contains("tabindex=\"-1\""))
        #expect(!html.contains("href="))
    }

    @MainActor
    @Test("A checkbox-styled toggle emits a real input carrying its checked state, floor-disabled")
    func emitsCheckboxAsInput() {
        // Checkbox itself is an internal type, only reachable through
        // Toggle's .checkbox style. Uniform-application consequence of the
        // tier-activation principle: its binding is dead without a runtime,
        // so it loads disabled + enlivened like every other form control,
        // even though nothing here called .disabled(true).
        // The checked/aria-checked *display* is still real.
        let html = StaticHTMLRenderer.render(
            Toggle("Subscribe", isOn: Self.box(true)).toggleStyle(.checkbox),
            context: "Checkbox"
        ).html

        #expect(html.contains("<input"))
        #expect(html.contains("type=\"checkbox\""))
        #expect(html.contains("checked=\"checked\""))
        #expect(html.contains("aria-checked=\"true\""))
        #expect(html.contains("disabled=\"disabled\""))
        #expect(html.contains("data-scui-enliven=\"js\""))
    }

    @MainActor
    @Test("A toggle preserves its label, reports state via aria-pressed, and loads floor-disabled")
    func emitsToggleLabelAndState() {
        // Toggle's default style is ToggleButton; the sweep confirmed the
        // label string "Enable notifications" was source-passed but 100%
        // absent from the emitted markup (G1). Same uniform-application
        // consequence as Checkbox above: no runtime, so no working binding.
        let html = StaticHTMLRenderer.render(
            Toggle("Enable notifications", isOn: Self.box(true)),
            context: "Toggle"
        ).html

        #expect(html.contains("Enable notifications"))
        #expect(html.contains("aria-pressed=\"true\""))
        #expect(html.contains("disabled=\"disabled\""))
        #expect(html.contains("data-scui-enliven=\"js\""))
    }

    @MainActor
    @Test("A slider emits a range input carrying its value and bounds, floor-disabled")
    func emitsSliderAsRangeInput() {
        let html = StaticHTMLRenderer.render(
            Slider(value: Self.box(0.4), in: 0.0...1.0),
            context: "Slider"
        ).html

        #expect(html.contains("<input"))
        #expect(html.contains("type=\"range\""))
        #expect(html.contains("min=\"0\""))
        #expect(html.contains("max=\"1\""))
        #expect(html.contains("value=\"0.4\""))
        #expect(html.contains("disabled=\"disabled\""))
        #expect(html.contains("data-scui-enliven=\"js\""))
    }

    @MainActor
    @Test("A text field preserves its value and placeholder text, floor-disabled")
    func emitsTextFieldWithValueAndPlaceholder() {
        let html = StaticHTMLRenderer.render(
            TextField("Your name", text: Self.box("Ada Lovelace")),
            context: "TextField"
        ).html

        #expect(html.contains("<input"))
        #expect(html.contains("type=\"text\""))
        #expect(html.contains("value=\"Ada Lovelace\""))
        #expect(html.contains("placeholder=\"Your name\""))
        #expect(html.contains("disabled=\"disabled\""))
        #expect(html.contains("data-scui-enliven=\"js\""))
    }

    @MainActor
    @Test("A secure field renders as a password input, not a plain text one")
    func emitsSecureFieldAsPasswordInput() {
        let html = StaticHTMLRenderer.render(
            SecureField("Password", text: Self.box("hunter2")),
            context: "SecureField"
        ).html

        #expect(html.contains("type=\"password\""))
        #expect(html.contains("value=\"hunter2\""))
    }

    @MainActor
    @Test("A disabled text field carries disabled semantics")
    func disabledTextFieldCarriesDisabledSemantics() {
        let html = StaticHTMLRenderer.render(
            TextField("Disabled field", text: Self.box("read only")).disabled(true),
            context: "Disabled text field"
        ).html

        #expect(html.contains("disabled=\"disabled\""))
        #expect(html.contains("aria-disabled=\"true\""))
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
            context: "Wrapping",
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
            context: "Overflow",
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
            context: "Flow",
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
    @Test("The root carries no width or height constraint of its own")
    func rootIsCompletelyFreeFlowing() {
        // The layout width is only a proposal for the SwiftCrossUI layout
        // pass (how Text wraps, how flexible frames resolve); it must not
        // reappear as a CSS constraint on #root. A measure is something the
        // author opts into with a nested .frame(maxWidth:), never something
        // the renderer imposes — see flexibleFrameReportsMinMaxConstraints
        // for the opt-in path.
        let html = StaticHTMLRenderer.render(
            Text("Body"),
            context: "Reflow",
            size: SIMD2(800, 600)
        ).html

        #expect(!html.contains("#root {"))
        #expect(!html.contains("max-width: 800px"))
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
            context: "VStack"
        ).html

        #expect(vertical.contains("flex-direction:column"))
        #expect(vertical.contains("gap:12px"))
        #expect(vertical.contains("align-items:flex-start"))

        let horizontal = StaticHTMLRenderer.render(
            HStack(spacing: 4) {
                Text("One")
                Text("Two")
            },
            context: "HStack"
        ).html

        #expect(horizontal.contains("flex-direction:row"))
        #expect(horizontal.contains("gap:4px"))
    }

    @MainActor
    @Test("A maxWidth panel centers itself inside a centered stack")
    func maxWidthPanelCentersInAFlexStack() {
        // The centering primitive is the stack's own align-items, not
        // anything the panel or the root contributes: a flex item on the
        // cross axis shrinks to its max-width and align-items:center
        // positions it, the same way a flow document centers a measured
        // column. No margin-inline:auto or root-level rule is needed.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .center) {
                Text("Header")
                Text("Panel").frame(maxWidth: 400)
            },
            context: "Centered panel",
            size: SIMD2(1400, 900)
        ).html

        let stackRule = Self.internedRule(containing: "flex-direction:column", in: html)
        #expect(stackRule?.contains("align-items:center") == true)

        let panelRule = Self.internedRule(containing: "max-width:400px", in: html)
        #expect(panelRule?.contains("max-width:400px") == true)
        // The panel itself carries no width/margin — centering comes purely
        // from the ancestor stack's align-items, not from anything emitted
        // on the panel's own rule.
        #expect(panelRule?.contains("margin") != true)
    }

    @MainActor
    @Test("multilineTextAlignment reaches CSS text-align, keying the interner off alignment")
    func multilineTextAlignmentEmitsTextAlign() {
        // Sweep finding G4: text-align never appeared in the emitter at all,
        // and — because Style is what the interner keys off — two
        // differently-aligned Text views with otherwise identical styling
        // collapsed onto the same class. Writing every case, including the
        // default .leading, is what keeps that from happening again: a
        // .center Text and a Text with no alignment declared must not share
        // a class just because .leading happens to be the CSS default too.
        let leading = StaticHTMLRenderer.render(Text("Leading"), context: "Leading").html
        let centered = StaticHTMLRenderer.render(
            Text("Centered").multilineTextAlignment(.center),
            context: "Centered"
        ).html
        let trailing = StaticHTMLRenderer.render(
            Text("Trailing").multilineTextAlignment(.trailing),
            context: "Trailing"
        ).html

        #expect(leading.contains("text-align:left"))
        #expect(centered.contains("text-align:center"))
        #expect(trailing.contains("text-align:right"))

        let leadingRule = Self.styleRule(forElementContaining: "<span", in: leading)
        let centeredRule = Self.styleRule(forElementContaining: "<span", in: centered)
        #expect(leadingRule != centeredRule)
    }

    @MainActor
    @Test("textSelectionEnabled(true) emits nothing; the framework default is user-select:none")
    func textSelectionDisabledEmitsUserSelectNone() {
        // Sweep finding G10: both selectable and unselectable Text interned
        // to the same class, because the modifier's value never reached
        // style computation. EnvironmentValues.isTextSelectionEnabled
        // defaults to false — every native backend maps it straight onto
        // the widget's own selectable flag with no inversion (AppKit's
        // NSTextField, UIKit's UILabel wrapper, Gtk's TextView all default
        // to unselectable text), so Text is genuinely unselectable unless an
        // author opts in with .textSelectionEnabled(true). Only that
        // enabled case is asserted to emit anything — the disabled default
        // is what needs the CSS override, not the enabled opt-in, so no
        // rule for the default case is the correct absence, not a gap.
        let unselectable = StaticHTMLRenderer.render(Text("Locked"), context: "Locked").html
        let selectable = StaticHTMLRenderer.render(
            Text("Selectable").textSelectionEnabled(true),
            context: "Selectable"
        ).html

        #expect(unselectable.contains("user-select:none"))
        #expect(!selectable.contains("user-select"))
    }

    @MainActor
    @Test("lineLimit emits line-clamp, and reservesSpace reserves real height")
    func lineLimitEmitsClampAndReservedSpace() {
        // Sweep finding G6: lineLimit(1) and lineLimit(2, reservesSpace:
        // true) were byte-identical in emitted output — no clamp, no
        // overflow, no reserved height, and no way to tell the two cases
        // apart. Font is required for the reservesSpace height computation
        // (line-height × limit), so a headline font declaration exercises
        // it deterministically.
        let clampedOnly = StaticHTMLRenderer.render(
            Text("Some text").lineLimit(2).font(.headline),
            context: "Clamped"
        ).html
        let reserving = StaticHTMLRenderer.render(
            Text("Some text").lineLimit(3, reservesSpace: true).font(.headline),
            context: "Reserving"
        ).html
        let unlimited = StaticHTMLRenderer.render(
            Text("Some text").font(.headline),
            context: "Unlimited"
        ).html

        let clampedRule = Self.styleRule(forElementContaining: "<span", in: clampedOnly)
        #expect(clampedRule?.contains("-webkit-line-clamp:2") == true)
        #expect(clampedRule?.contains("overflow:hidden") == true)
        #expect(clampedRule?.contains("min-height:") != true)

        let reservingRule = Self.styleRule(forElementContaining: "<span", in: reserving)
        #expect(reservingRule?.contains("-webkit-line-clamp:3") == true)
        #expect(reservingRule?.contains("min-height:") == true)

        #expect(!unlimited.contains("-webkit-line-clamp"))
        #expect(!unlimited.contains("overflow:hidden"))
    }

    @MainActor
    @Test("Spacer gets flex:1 1 0%, not an empty class")
    func spacerEmitsFlexGrow() {
        // Spacer's committed Container widget has to carry flex-grow and
        // flex-basis; with an empty class it collapses in a flex row and its
        // siblings sit adjacent instead of being pushed apart.
        // Spacer has no dedicated Widget subclass, so recognising it here
        // relies on ``BackendFeatures/Widgets/describeSpacer(of:)`` (task
        // #32), which is also what the real layoutPriority(-infinity)
        // signal (never reaching the backend) is standing in for here.
        let html = StaticHTMLRenderer.render(
            HStack {
                Text("Leading")
                Spacer()
                Text("Trailing")
            },
            context: "Spacer"
        ).html

        let spacerRule = Self.styleRule(forElementContaining: "data-scui=\"Spacer\"", in: html)
        #expect(spacerRule?.contains("flex:1 1 0%") == true)
    }

    @MainActor
    @Test("layoutPriority gives the higher-priority child less flex-shrink under a squeeze")
    func layoutPriorityWeightsFlexShrink() {
        // Sweep finding G5: under a deliberately constrained frame, two Text
        // children behaved identically regardless of layoutPriority — no
        // flex-grow/flex-shrink anywhere in the emitter at all, because the
        // value never reached the backend in the first place (see
        // LayoutSystem.commitStackLayout's describeChildLayoutPriorities
        // call). This reproduces that exact shape: two children whose
        // natural widths add up to more than the 260px the HStack is
        // squeezed into, one of them with a higher declared priority.
        //
        // No .htmlTag()/.htmlAttributes() here: layoutPriority wraps its
        // view in its own PreferenceModifier container, which is what
        // actually lands as the HStack's direct child (and so is what
        // carries flex-shrink) — an explicit tag on the Text leaf would
        // hoist onto a *different* element than the one under test. The
        // priority-0 leading Text stays an unwrapped span, so the two
        // classes are told apart by which element carries which, in
        // document order: the plain <span> is the low-priority child, the
        // wrapping <div data-scui="PreferenceModifier"> is the high-priority
        // one.
        let squeezed = StaticHTMLRenderer.render(
            HStack {
                Text("Long leading label text")
                Text("Long trailing label text").layoutPriority(1)
            }
            .frame(width: 260),
            context: "Squeezed priority"
        ).html

        let lowRule = Self.styleRule(forElementContaining: "<span", in: squeezed)
        let highRule = Self.styleRule(
            forElementContaining: "data-scui=\"PreferenceModifier\"",
            in: squeezed
        )
        #expect(lowRule?.contains("flex-shrink:") == true)
        #expect(highRule?.contains("flex-shrink:") == true)

        // The higher-priority child must end up with a *smaller* shrink
        // factor — it gives up less space, matching layoutPriority's
        // documented "resists shrinking" contract — not just *some*
        // flex-shrink value.
        func shrinkValue(_ rule: String?) -> Double? {
            guard let rule, let range = rule.range(of: "flex-shrink:") else {
                return nil
            }
            let rest = rule[range.upperBound...]
            let digits = rest.prefix { $0.isNumber || $0 == "." }
            return Double(digits)
        }
        let lowShrink = shrinkValue(lowRule)
        let highShrink = shrinkValue(highRule)
        #expect(lowShrink != nil && highShrink != nil)
        if let lowShrink, let highShrink {
            #expect(highShrink < lowShrink)
        }

        // A stack whose children never diverge on layoutPriority is the
        // common case, and must stay exactly as before: no flex-shrink at
        // all, so an author who never touched the modifier sees no new CSS.
        let uniform = StaticHTMLRenderer.render(
            HStack {
                Text("One")
                Text("Two")
            },
            context: "Uniform priority"
        ).html
        #expect(!uniform.contains("flex-shrink"))
    }

    @MainActor
    @Test("Divider stretches via flex, not a pinned min-width that would overflow")
    func dividerStretchesWithoutOverflowing() {
        // Divider's un-declared axis (Divider only declares
        // .frame(height: 1); width is intentionally left to the layout
        // system) must not inherit a min-width pinned to whatever
        // stretch-to-fill computed at this one render width — such a
        // min-width overflows every narrower viewport.
        //
        // Stretch is chained instead, from the widget
        // ``BackendFeatures/Widgets/describeDivider(of:)`` marks down to the
        // leaf, three wrappers deep (Divider → StrictFrameView → Color),
        // because
        // flex's stretch only applies on the CROSS axis of whichever flex
        // container is doing the stretching:
        //   - Divider's own wrapper gets align-self:stretch against the
        //     VStack's align-items:center (verified live: without this,
        //     Divider shrink-wraps to zero width against a centered parent).
        //   - StrictFrameView's wrapper (which has no stackLayout of its
        //     own, so it doesn't naturally become flex at all) gets
        //     display:flex + flex-direction:column *and* its own
        //     align-self:stretch — column because Divider's undeclared axis
        //     is width, and column is what puts width on the cross axis.
        //   - The Color leaf itself needs no CSS of its own on that axis:
        //     flex's default align-items is already stretch, so simply not
        //     emitting a competing min-width lets it fill.
        // width:100% on the leaf is not a substitute: it only works if every
        // ancestor's own width has already resolved to something non-zero,
        // and it fails silently through however many wrapper levels
        // shrink-wrap by default. Distinguishing the two needs computed
        // widths measured in a browser, not an inspection of the CSS text.
        let html = StaticHTMLRenderer.render(
            VStack {
                Text("Above")
                Divider()
                Text("Below")
            },
            context: "Divider"
        ).html

        #expect(!html.contains("min-width:800px"))

        let dividerRule = Self.styleRule(
            forElementContaining: "data-scui=\"Divider\"",
            in: html
        )
        #expect(dividerRule?.contains("align-self:stretch") == true)

        let frameRule = Self.styleRule(
            forElementContaining: "data-scui=\"StrictFrameView\"",
            in: html
        )
        #expect(frameRule?.contains("align-self:stretch") == true)
        #expect(frameRule?.contains("display:flex") == true)
        #expect(frameRule?.contains("flex-direction:column") == true)

        let colorRule = Self.styleRule(forElementContaining: "data-scui=\"Color\"", in: html)
        #expect(colorRule?.contains("height:1px") == true)
        // No width declaration at all on the leaf — flex's own default
        // stretch is what fills it, not a percentage the leaf asserts
        // about its own box.
        #expect(colorRule?.contains("width:") != true)
    }

    @MainActor
    @Test(
        "A bare Color hairline under .frame(maxWidth: .infinity) stretches like Divider, without Divider's marker"
    )
    func infiniteFrameColorStretchesWithoutDividerMarker() {
        // A hand-built hairline (`Color.frame(maxWidth: .infinity,
        // maxHeight:)`, the shape `PageLayout`/`DesignSystemPage` use for
        // `Theme.border`) carries the same "stretch to fill" intent as
        // Divider but has no `isDivider` marker. It must still avoid a
        // min-width floor pinned to the build host's committed width — that
        // floor overflows any narrower render width, and (since nothing
        // downstream carries max-width:100%) drags every ancestor it shares
        // with unrelated siblings wide enough to block their own wrapping.
        let html = StaticHTMLRenderer.render(
            VStack {
                Text("Above")
                Color.gray
                    .frame(maxWidth: .infinity, maxHeight: 1)
                Text("Below")
            },
            context: "Bare stretching hairline",
            size: SIMD2(800, 200)
        ).html

        #expect(!html.contains("min-width:800px"))

        // The stretch and max-height CSS lands on the FlexibleFrameView
        // wrapper the `.frame(maxWidth:maxHeight:)` modifier introduces
        // (mirroring Divider's own StrictFrameView wrapper above) — the
        // Color leaf inside it carries no width declaration of its own,
        // which is what lets flex's default stretch fill it.
        let frameRule = Self.styleRule(
            forElementContaining: "data-scui=\"FlexibleFrameView\"",
            in: html
        )
        #expect(frameRule?.contains("align-self:stretch") == true)
        #expect(frameRule?.contains("max-height:1px") == true)

        let colorRule = Self.styleRule(forElementContaining: "data-scui=\"Color\"", in: html)
        #expect(colorRule?.contains("min-width:") != true)
        #expect(colorRule?.contains("width:") != true)
    }

    @MainActor
    @Test(
        "aspectRatio emits CSS aspect-ratio so the undeclared axis scales proportionally under reflow"
    )
    func aspectRatioEmitsProportionalCSS() {
        // AspectRatioModifier is a pure layout-proposal transform with no
        // widget of its own, so emitting its committed size (300x150, i.e.
        // 2:1 at width:300) would be exact only at the width the build host
        // proposed. Under this emitter's reflow philosophy — everything here
        // re-derives from declared intent at every width — a declared ratio
        // on flexible-width content has to scale proportionally in the
        // browser, or it silently stops being 2:1 the moment the reader
        // resizes. ``BackendFeatures/Widgets/describeAspectRatio(of:ratio:contentMode:)``
        // carries the author's ratio to the backend for exactly this case;
        // AspectRatioView.commit calls it with `nil` when the view instead
        // adopted its child's own ideal ratio (no explicit value given),
        // since that's a layout-computed value with nothing safe to
        // re-derive — this test only covers the explicit-ratio path.
        let html = StaticHTMLRenderer.render(
            Color.blue.aspectRatio(2.0, contentMode: .fit).frame(width: 300),
            context: "AspectRatio"
        ).html

        let leafRule = Self.styleRule(
            forElementContaining: "data-scui=\"AspectRatioView\"",
            in: html
        )
        #expect(leafRule?.contains("width:300px") == true)
        #expect(leafRule?.contains("aspect-ratio:2") == true)
        // The baked cross-axis floor from #22 is gone: a min-height here
        // would win the intrinsic-size negotiation over aspect-ratio at
        // some widths and silently reintroduce the fixed-ratio-only bug
        // this test now guards against.
        #expect(leafRule?.contains("min-height:") != true)
    }

    @MainActor
    @Test(
        "Responsive environment values default honestly for a one-shot build-host render"
    )
    func responsiveEnvironmentValuesCarryDocumentedStaticDefaults() {
        // reducedMotion, pointerCapability, and printActive are the
        // MEASURING-tier halves of future GeometrySelector.Condition
        // cases — populated where a runtime CAN know them, which
        // StaticHTMLBackend never can (it's always a one-shot build-host
        // render with no reader to ask). This locks in the documented
        // defaults rather than leaving them to accidental drift: .fine
        // (not .coarse) for pointer capability specifically, since a wrong
        // .coarse default would suppress desktop-density layouts, the
        // costlier mistake of the two.
        struct EnvironmentProbe: View {
            @Environment(\.reducedMotion) var reducedMotion
            @Environment(\.pointerCapability) var pointerCapability
            @Environment(\.printActive) var printActive

            var body: some View {
                Text("\(reducedMotion) \(pointerCapability) \(printActive)")
            }
        }

        let html = StaticHTMLRenderer.render(EnvironmentProbe(), context: "ResponsiveEnv").html

        #expect(html.contains("noPreference"))
        #expect(html.contains("fine"))
        #expect(html.contains("false"))
    }

    @MainActor
    @Test("Padding becomes CSS padding rather than an offset child")
    func emitsPaddingAsCSSPadding() {
        let html = StaticHTMLRenderer.render(
            Text("Inset").padding(24),
            context: "Padding"
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
            context: "Frame"
        ).html

        // A declared frame is the only way an author pins geometry, so it's
        // the only thing that survives into output that otherwise reflows.
        #expect(html.contains("width:300px"))
        // The frame sets the measure; it doesn't stop the text flowing inside
        // it, and its leftover space must not be read back as padding — but
        // scoped to the interner's own class-rule syntax (`property:value`,
        // no space, semicolon-separated within one `{ }` block). The
        // button/input reset legitimately declares its own `padding: 0;`
        // (spaced, standalone CSS, not an interned class) in every
        // document's global stylesheet, so a bare "padding" substring search
        // would match that too.
        #expect(!html.contains("position:absolute"))
        #expect(!html.contains("padding:0"))
        #expect(!html.contains("padding:300"))
    }

    @MainActor
    @Test("Only overlapping children fall back to absolute positioning")
    func onlyOverlappingChildrenAreAbsolutelyPositioned() {
        let overlapping = StaticHTMLRenderer.render(
            ZStack {
                Color.blue.frame(width: 200, height: 60)
                Text("Overlaid")
            },
            context: "ZStack"
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
            context: "Flow"
        ).html
        #expect(!sideBySide.contains("position:absolute"))
    }

    @MainActor
    @Test("Content with no intrinsic size keeps the size it was given")
    func keepsExplicitSizeForContentWithoutIntrinsicSize() {
        let html = StaticHTMLRenderer.render(
            Color.blue.frame(width: 320, height: 4),
            context: "Frame"
        ).html

        // A rectangle has nothing inside it to derive a height from, so
        // dropping its committed size would collapse it entirely. Both axes
        // are exact declarations here (.frame(width:height:), not a
        // flexible range), so they're pinned exactly as `width`/`height`,
        // not floored as `min-width`/`min-height`. That distinction is what
        // separates an author-declared axis from one the layout system
        // merely stretched to fill — see the Divider stretch test above.
        #expect(html.contains("width:320px"))
        #expect(html.contains("height:4px"))
        #expect(!html.contains("min-width"))
        #expect(!html.contains("min-height"))
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
