import Testing

import StaticHTMLBackend
@_spi(Backends) import SwiftCrossUI

@Suite("Testing the responsive type scale")
struct StaticHTMLTypeScaleTests {
    @MainActor
    @Test("A declared text style emits its properties and references them")
    func declaredStyleRidesCustomProperties() {
        let html = StaticHTMLRenderer.render(
            Text("Body copy").font(.body),
            context: "Type"
        ).html

        // The definition lands in the head…
        #expect(html.contains("--scui-fs-body: 17px;"))
        #expect(html.contains("--scui-lh-body: 22px;"))
        #expect(html.contains("--scui-fw-body: 400;"))

        // …and the class references it rather than baking a pixel value.
        #expect(html.contains("font-size:var(--scui-fs-body)"))
        #expect(html.contains("line-height:var(--scui-lh-body)"))
        #expect(html.contains("font-weight:var(--scui-fw-body)"))
    }

    @MainActor
    @Test("Only the text styles a page actually used are emitted")
    func emissionIsConditional() {
        let html = StaticHTMLRenderer.render(
            Text("Body copy").font(.body),
            context: "Type"
        ).html

        #expect(html.contains("--scui-fs-body:"))
        // Nothing else on the ramp reached the document, so nothing else is
        // defined — the same conditional-emission rule the color palette
        // follows.
        #expect(!html.contains("--scui-fs-large-title:"))
        #expect(!html.contains("--scui-fs-caption:"))
        #expect(!html.contains("--scui-fs-footnote:"))
    }

    @MainActor
    @Test("A page with no dynamic text styles carries no type-scale block")
    func noStylesMeansNoMachinery() {
        let html = StaticHTMLRenderer.render(
            Text("Fixed").font(.system(size: 13)),
            context: "Type"
        ).html

        #expect(!html.contains("--scui-fs-"))
        #expect(!html.contains("@media (max-width: 600px)"))
    }

    @MainActor
    @Test("The compact media query overrides display sizes and only those")
    func compactQueryStepsDownDisplaySizesOnly() {
        let view = VStack {
            Text("Title").font(.largeTitle)
            Text("Body copy").font(.body)
        }
        let html = StaticHTMLRenderer.render(view, context: "Type").html

        #expect(html.contains("@media (max-width: 600px)"))

        guard let mediaRange = html.range(of: "@media (max-width: 600px)") else {
            Issue.record("no compact block emitted")
            return
        }
        let compactBlock = String(html[mediaRange.lowerBound...])

        // largeTitle is a display size, so it steps down…
        #expect(compactBlock.contains("--scui-fs-large-title: 28px;"))
        // …while body is the anchor and must not appear in the override at
        // all. 17px is the reading size at every width.
        #expect(!compactBlock.contains("--scui-fs-body:"))
    }

    @MainActor
    @Test("Headline and Body share a size but keep different weights")
    func weightDifferentiationSurvives() {
        let view = VStack {
            Text("Lede").font(.headline)
            Text("Body copy").font(.body)
        }
        let html = StaticHTMLRenderer.render(view, context: "Type").html

        // Apple's own mitigation for the collision: same size, heavier
        // weight. If the scale ever flattened weight into a shared property,
        // the two would become indistinguishable.
        #expect(html.contains("--scui-fs-headline: 17px;"))
        #expect(html.contains("--scui-fs-body: 17px;"))
        #expect(html.contains("--scui-fw-headline: 600;"))
        #expect(html.contains("--scui-fw-body: 400;"))
    }

    @MainActor
    @Test("An explicitly-sized font keeps literal pixels")
    func explicitSizesStayLiteral() {
        let html = StaticHTMLRenderer.render(
            Text("Fixed").font(.system(size: 13)),
            context: "Type"
        ).html

        #expect(html.contains("font-size:13px"))
        #expect(!html.contains("font-size:var("))
    }

    @MainActor
    @Test("A text style carrying a modifier falls back to literal pixels")
    func modifiedStylesFallBackToLiterals() {
        // This pins a KNOWN LIMITATION so it reads as designed rather than
        // accidental. Font.Resolved keeps no record of the style it came
        // from, so attribution goes through the un-resolved font — and any
        // modifier makes that font compare unequal to the bare constant.
        // Publishing a modified font as var(--scui-fs-body) would silently
        // drop the modifier at every width, so it stays literal instead.
        //
        // Lifting this needs a way to decompose a Font into style-plus-overlay,
        // which the type doesn't currently expose.
        let html = StaticHTMLRenderer.render(
            Text("Heavy").font(.body.weight(.black)),
            context: "Type"
        ).html

        #expect(html.contains("font-weight:900"))
        #expect(!html.contains("font-size:var("))
        #expect(!html.contains("--scui-fs-body:"))
    }

    @MainActor
    @Test("A bare style declared via system(_:) is still attributable")
    func systemSugarIsAttributable() {
        // Font.system(.body) constructs the same value as Font.body, so the
        // sugar has to reach the properties too — otherwise which spelling
        // the author picked would silently change the output.
        let html = StaticHTMLRenderer.render(
            Text("Body copy").font(.system(.body)),
            context: "Type"
        ).html

        #expect(html.contains("font-size:var(--scui-fs-body)"))
    }

    @MainActor
    @Test("Derived headings ride the properties like any other text")
    func headingsRideTheProperties() {
        let html = StaticHTMLRenderer.render(
            Text("Doc Title").font(.largeTitle),
            context: "Type"
        ).html

        // HeadingMap still derives the element from the declared style…
        #expect(html.contains("<h1"))
        // …and the size that element renders at comes from the scale.
        #expect(html.contains("font-size:var(--scui-fs-large-title)"))
    }

    @MainActor
    @Test("Two elements sharing a text style share one interned class")
    func identicalStylesShareAClass() {
        let view = VStack {
            Text("First").font(.body)
            Text("Second").font(.body)
        }
        let html = StaticHTMLRenderer.render(view, context: "Type").html

        // One rule mentioning the body property, not two.
        let bodyRules = html.components(
            separatedBy: "font-size:var(--scui-fs-body)"
        ).count - 1
        #expect(bodyRules == 1)
    }

    @MainActor
    @Test("Property definitions precede the classes that reference them")
    func propertiesComeBeforeReferences() {
        let html = StaticHTMLRenderer.render(
            Text("Body copy").font(.body),
            context: "Type"
        ).html

        guard
            let definition = html.range(of: "--scui-fs-body: 17px;"),
            let reference = html.range(of: "font-size:var(--scui-fs-body)")
        else {
            Issue.record("expected both a definition and a reference")
            return
        }
        #expect(definition.lowerBound < reference.lowerBound)
    }

    @MainActor
    @Test("The color palette and the type scale coexist in one style block")
    func schemeMachineryIsUnaffected() {
        let html = StaticHTMLRenderer.render(
            Text("Body copy").font(.body).foregroundColor(.red),
            context: "Type"
        ).html

        // The palette's own dark-scheme swap still emits, unchanged by the
        // type scale sharing the block.
        #expect(html.contains("@media (prefers-color-scheme: dark)"))
        #expect(html.contains("--scui-fs-body:"))
    }
}
