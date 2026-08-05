import Testing

import Foundation
import StaticHTMLBackend
@_spi(Backends) import SwiftCrossUI
import SwiftCrossUIComponents

@Suite("Testing shape and gradient emission for the static HTML backend")
struct StaticHTMLShapeTests {
    @MainActor
    @Test("A Rectangle emits its outline as SVG path data, not a styled box")
    func rectangleEmitsPathData() {
        // A shape reaches the backend as flattened Path.Actions with no record
        // of the view that produced them (Shape.commit calls path(in:) first),
        // so the emitter has nothing to branch on that would let the five
        // built-in shapes become border-radius. SVG carries the actions
        // themselves.
        let html = Self.render(Rectangle().fill(.red).frame(width: 100, height: 60))

        #expect(html.contains("<svg"))
        #expect(html.contains("viewBox=\"0 0 100 60\""))
        #expect(Self.pathData(in: html) == "M 0 0 H 100 V 60 H 0 Z")
    }

    @MainActor
    @Test("A Circle's full turn becomes two arcs, which SVG can express")
    func circleEmitsTwoArcs() {
        // SVG's arc command draws nothing when its start and end coincide, so
        // a full circle can't be one command.
        let html = Self.render(Circle().fill(.red).frame(width: 80, height: 80))

        #expect(Self.pathData(in: html) == "M 0 40 A 40 40 0 1 1 80 40 A 40 40 0 1 1 0 40 Z")
    }

    @MainActor
    @Test("An Ellipse's transform reaches the emitted radii")
    func ellipseTransformScalesRadii() {
        // Ellipse is a circle plus an AffineTransform, and SVG path data has no
        // transform operator — the coordinates have to be mapped as they're
        // written, including the arc radii, which aren't a coordinate pair.
        let html = Self.render(Ellipse().fill(.red).frame(width: 100, height: 60))

        #expect(Self.pathData(in: html) == "M 0 30 A 50 30 0 1 1 100 30 A 50 30 0 1 1 0 30 Z")
    }

    @MainActor
    @Test("A RoundedRectangle's superellipse corners survive as curves")
    func roundedRectangleEmitsCurves() {
        let html = Self.render(
            RoundedRectangle(cornerRadius: 12).fill(.red).frame(width: 100, height: 60)
        )
        let data = Self.pathData(in: html)

        // The corner approximation is cubic curves rather than arcs at this
        // radius-to-side ratio, and the outline closes back on its start.
        #expect(data?.contains("C ") == true)
        #expect(data?.hasPrefix("M 50 0") == true)
        #expect(data?.hasSuffix("L 50 0") == true)
    }

    @MainActor
    @Test("A Capsule's half-circle ends emit as arcs")
    func capsuleEmitsArcs() {
        let html = Self.render(Capsule().fill(.red).frame(width: 100, height: 40))
        let data = Self.pathData(in: html)

        // A capsule's corner radius is half its shortest side, which is the
        // ratio at which RoundedRectangle switches to circular arcs.
        #expect(data?.contains("A 20 20 ") == true)
    }

    @MainActor
    @Test("A stroked shape carries its stroke style, and an unfilled one no fill")
    func strokeStyleReachesTheMarkup() {
        let html = Self.render(
            Circle().stroke(.blue, style: StrokeStyle(width: 4, cap: .round, join: .bevel))
                .frame(width: 80, height: 80)
        )
        let path = Self.pathElement(in: html)

        #expect(path?.contains("stroke-width=\"4\"") == true)
        #expect(path?.contains("stroke-linecap=\"round\"") == true)
        #expect(path?.contains("stroke-linejoin=\"bevel\"") == true)
        // .stroke() leaves the fill half clear; a fully transparent paint would
        // render nothing while still interning a class for the color.
        #expect(path?.contains("fill=\"none\"") == true)
    }

    @MainActor
    @Test("An unstroked shape emits no stroke attributes at all")
    func unstrokedShapeOmitsStroke() {
        // Shape's default resolves to a clear stroke at width 1 rather than to
        // width 0, so a width check alone wouldn't keep the paint out.
        let html = Self.render(Rectangle().fill(.red).frame(width: 100, height: 60))
        let path = Self.pathElement(in: html)

        #expect(path?.contains("stroke=") == false)
        #expect(path?.contains("fill=\"none\"") == false)
    }

    @MainActor
    @Test("A shape is hidden from assistive technology unless the author labels it")
    func shapeIsDecorativeByDefault() {
        let plain = Self.render(Circle().fill(.red).frame(width: 40, height: 40))
        #expect(plain.contains("aria-hidden=\"true\""))

        let labelled = Self.render(
            Circle().fill(.red).frame(width: 40, height: 40)
                .htmlAttributes(["aria-label": "Status"])
        )
        #expect(!labelled.contains("aria-hidden=\"true\""))
        #expect(labelled.contains("aria-label=\"Status\""))
    }

    @MainActor
    @Test("A linear gradient's two points become a CSS angle")
    func linearGradientAngle() {
        // CSS measures clockwise from "to top"; the view's points are in a
        // y-down space, so top-to-bottom is 180deg and leading-to-trailing 90.
        let vertical = Self.render(
            LinearGradient(colors: [.red, .blue], startPoint: .top, endPoint: .bottom)
                .frame(width: 100, height: 60)
        )
        #expect(Self.rule(containing: "linear-gradient", in: vertical)?
            .contains("linear-gradient(180deg,") == true)

        let horizontal = Self.render(
            LinearGradient(colors: [.red, .blue], startPoint: .leading, endPoint: .trailing)
                .frame(width: 100, height: 60)
        )
        #expect(Self.rule(containing: "linear-gradient", in: horizontal)?
            .contains("linear-gradient(90deg,") == true)
    }

    @MainActor
    @Test("A radial gradient centers on its unit point")
    func radialGradientCenter() {
        let html = Self.render(
            RadialGradient(colors: [.red, .blue], center: .center, startRadius: 0, endRadius: 50)
                .frame(width: 100, height: 100)
        )

        #expect(Self.rule(containing: "radial-gradient", in: html)?
            .contains("radial-gradient(circle at 50% 50%,") == true)
    }

    @MainActor
    @Test("An angular gradient becomes a conic gradient from its start angle")
    func angularGradientIsConic() {
        let html = Self.render(
            AngularGradient(colors: [.red, .blue], center: .center, angle: .degrees(90))
                .frame(width: 100, height: 100)
        )

        #expect(Self.rule(containing: "conic-gradient", in: html)?
            .contains("conic-gradient(from 90deg at 50% 50%,") == true)
    }

    @MainActor
    @Test("A radial gradient's start radius reaches the stops CSS can express")
    func radialStartRadiusBecomesStopPositions() {
        // CSS radial-gradient has no inner radius, so core's adjustedStops
        // expresses one as stop positions instead — without it, the solid
        // center a start radius describes would be lost.
        let html = Self.render(
            RadialGradient(colors: [.red, .blue], center: .center, startRadius: 25, endRadius: 50)
                .frame(width: 100, height: 100)
        )
        let rule = Self.rule(containing: "radial-gradient", in: html)

        #expect(rule?.contains(" 50%,") == true)
        #expect(rule?.contains(" 0%,") == false)
    }

    @MainActor
    @Test("Gradient stops resolve scheme by scheme, not gradient by gradient")
    func gradientStopsCarryPerStopSchemeValues() {
        // Each stop is its own color, so a gradient mixing a scheme-varying
        // color with a fixed one must emit a custom property for the first and
        // a literal for the second — a per-gradient decision would push the
        // fixed stop into the palette too.
        let html = Self.render(SchemeVaryingGradient())
        let rule = Self.rule(containing: "linear-gradient", in: html)

        #expect(rule?.contains("var(--scui-c0)") == true)
        #expect(rule?.contains("rgba(20,30,40,1.0)") == true)

        // The varying stop's two values have to differ, which is the whole
        // point of the property; a palette that emitted the same color in both
        // blocks would satisfy the reference check above but render one scheme
        // wrong.
        #expect(html.contains("@media (prefers-color-scheme: dark)"))
        let light = Self.customProperty("--scui-c0", in: html, afterDarkQuery: false)
        let dark = Self.customProperty("--scui-c0", in: html, afterDarkQuery: true)
        #expect(light != nil)
        #expect(dark != nil)
        #expect(light != dark)
    }

    @MainActor
    @Test("Two gradients agreeing on geometry and stops share one class")
    func identicalGradientsIntern() {
        let html = Self.render(
            VStack {
                LinearGradient(colors: [.red, .blue], startPoint: .top, endPoint: .bottom)
                    .frame(width: 100, height: 60)
                LinearGradient(colors: [.red, .blue], startPoint: .top, endPoint: .bottom)
                    .frame(width: 100, height: 60)
            }
        )
        let rules = html.split(separator: "\n").filter { $0.contains("linear-gradient(") }

        #expect(rules.count == 1)
    }

    /// Renders a view at a fixed size, with no document furniture in the way.
    @MainActor
    private static func render(_ view: some View) -> String {
        StaticHTMLRenderer.render(view, context: "Shapes", size: SIMD2(400, 300)).html
    }

    /// The first `<path>` element in the markup.
    private static func pathElement(in html: String) -> String? {
        html.split(separator: "\n")
            .first { $0.contains("<path ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The `d` attribute of the first `<path>` element.
    private static func pathData(in html: String) -> String? {
        guard
            let element = pathElement(in: html),
            let start = element.range(of: "d=\"")
        else {
            return nil
        }
        let rest = element[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else {
            return nil
        }
        return String(rest[..<end])
    }

    /// The first stylesheet rule containing a marker.
    private static func rule(containing marker: String, in html: String) -> String? {
        html.split(separator: "\n").first { $0.contains(marker) }.map(String.init)
    }

    /// The value of a custom property, in either the light or dark block.
    ///
    /// - Parameters:
    ///   - name: The property to look up.
    ///   - html: The document to search.
    ///   - afterDarkQuery: Whether to read the value from the dark-scheme
    ///     block rather than the `:root` one.
    /// - Returns: The property's value, if the block defines it.
    private static func customProperty(
        _ name: String,
        in html: String,
        afterDarkQuery: Bool
    ) -> String? {
        var reachedDarkQuery = false
        for line in html.split(separator: "\n") {
            if line.contains("@media (prefers-color-scheme: dark)") {
                reachedDarkQuery = true
                continue
            }
            guard reachedDarkQuery == afterDarkQuery else {
                continue
            }
            guard let range = line.range(of: "\(name): ") else {
                continue
            }
            return String(line[range.upperBound...]).trimmingCharacters(
                in: CharacterSet(charactersIn: " ;")
            )
        }
        return nil
    }
}

/// A gradient whose first stop follows the color scheme and whose second
/// doesn't, so the two halves of the palette decision appear in one value.
private struct SchemeVaryingGradient: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        LinearGradient(
            colors: [
                colorScheme.defaultForegroundColor,
                Color(red: 20 / 255, green: 30 / 255, blue: 40 / 255),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: 100, height: 60)
    }
}

/// Writes a fixture page exercising every shape and gradient, for the browser
/// paint check in `Scripts/check-shape-paint.mjs`.
@Suite(
    "Shape fixture generation",
    .enabled(
        if: ProcessInfo.processInfo.environment["SCUI_WRITE_SHAPE_FIXTURE"] != nil,
        "Set SCUI_WRITE_SHAPE_FIXTURE to refresh the browser paint fixture"
    )
)
struct StaticHTMLShapeFixture {
    @MainActor
    @Test("Write the fixture")
    func write() throws {
        let html = StaticHTMLRenderer.render(
            VStack(spacing: 20) {
                Rectangle().fill(.red).frame(width: 120, height: 60)
                    .htmlAttributes(["id": "rectangle"])
                RoundedRectangle(cornerRadius: 16).fill(.green).frame(width: 120, height: 60)
                    .htmlAttributes(["id": "rounded"])
                Circle().fill(.blue).frame(width: 80, height: 80)
                    .htmlAttributes(["id": "circle"])
                Ellipse().fill(.orange).frame(width: 120, height: 60)
                    .htmlAttributes(["id": "ellipse"])
                Capsule().fill(.purple).frame(width: 120, height: 40)
                    .htmlAttributes(["id": "capsule"])
                Circle().stroke(.black, style: StrokeStyle(width: 6))
                    .frame(width: 80, height: 80)
                    .htmlAttributes(["id": "stroked"])
                LinearGradient(colors: [.red, .blue], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 200, height: 60)
                    .htmlAttributes(["id": "linear"])
                RadialGradient(
                    colors: [.yellow, .blue],
                    center: .center,
                    startRadius: 0,
                    endRadius: 60
                )
                .frame(width: 120, height: 120)
                .htmlAttributes(["id": "radial"])
                AngularGradient(colors: [.red, .green, .blue, .red], center: .center)
                    .frame(width: 120, height: 120)
                    .htmlAttributes(["id": "angular"])
            },
            context: "Shape paint fixture",
            size: SIMD2(600, 900)
        ).html

        try html.write(
            toFile: "/tmp/scui-shape-fixture.html",
            atomically: true,
            encoding: .utf8
        )
    }
}
