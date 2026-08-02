import DummyBackend
import Foundation
import Testing

@testable import StaticHTMLBackend

@_spi(Backends) import SwiftCrossUI

@Suite("Testing GeometrySelector: validation, emission, and gating CSS")
@MainActor
struct GeometrySelectorTests {

    /// A minimal branch for validation tests — content is irrelevant to
    /// `validationErrors(for:)`, which only reasons about ranges.
    private func branch(_ id: Int, _ range: WidthRange?) -> GSelBranch {
        GSelBranch(id: id, range: range, content: AnyView(EmptyView()))
    }

    // MARK: - Validation

    @Test("Overlapping WidthCase ranges are rejected")
    func rejectsOverlappingRanges() {
        let errors = GeometrySelector.validationErrors(for: [
            branch(0, WidthRange(..<700)),
            branch(1, WidthRange(600...)),
        ])
        #expect(!errors.isEmpty)
        #expect(errors.contains { $0.contains("overlap") })
    }

    @Test("A gap with no fallback is rejected")
    func rejectsGapWithoutFallback() {
        let errors = GeometrySelector.validationErrors(for: [
            branch(0, WidthRange(..<600)),
            branch(1, WidthRange(900...)),
        ])
        #expect(!errors.isEmpty)
        #expect(errors.contains { $0.contains("between 600.0 and 900.0") })
    }

    @Test("An unbounded-below gap with no fallback is rejected")
    func rejectsUnboundedBelowGapWithoutFallback() {
        let errors = GeometrySelector.validationErrors(for: [
            branch(0, WidthRange(600..<900))
        ])
        #expect(errors.contains { $0.contains("no branch covers widths below 600.0") })
    }

    @Test("An unbounded-above gap with no fallback is rejected")
    func rejectsUnboundedAboveGapWithoutFallback() {
        let errors = GeometrySelector.validationErrors(for: [
            branch(0, WidthRange(..<600)),
            branch(1, WidthRange(600..<900)),
        ])
        #expect(errors.contains { $0.contains("no branch covers widths at or above 900.0") })
    }

    @Test("A gap covered by a fallback is accepted")
    func acceptsGapWithFallback() {
        let errors = GeometrySelector.validationErrors(for: [
            branch(0, WidthRange(..<600)),
            branch(1, WidthRange(900...)),
            branch(2, nil),
        ])
        #expect(errors.isEmpty)
    }

    @Test("Adjacent ranges with no gap need no fallback")
    func acceptsAdjacentRangesWithoutFallback() {
        let errors = GeometrySelector.validationErrors(for: [
            branch(0, WidthRange(..<600)),
            branch(1, WidthRange(600...)),
        ])
        #expect(errors.isEmpty)
    }

    @Test("A GeometrySelector with no branches is rejected")
    func rejectsEmptyBranchList() {
        let errors = GeometrySelector.validationErrors(for: [])
        #expect(!errors.isEmpty)
        #expect(errors.contains { $0.contains("at least one WidthCase") })
    }

    @Test("Two branches sharing an unbounded direction overlap")
    func rejectsDoublyUnboundedOverlap() {
        let errors = GeometrySelector.validationErrors(for: [
            branch(0, WidthRange(600...)),
            branch(1, WidthRange(900...)),
        ])
        #expect(errors.contains { $0.contains("overlap") })
    }

    @Test("A fallback alone, with no WidthCase, is accepted")
    func acceptsFallbackOnly() {
        let errors = GeometrySelector.validationErrors(for: [branch(0, nil)])
        #expect(errors.isEmpty)
    }

    @Test("Three non-overlapping, gap-free ranges need no fallback")
    func acceptsThreeAdjacentRanges() {
        let errors = GeometrySelector.validationErrors(for: [
            branch(0, WidthRange(..<600)),
            branch(1, WidthRange(600..<900)),
            branch(2, WidthRange(900...)),
        ])
        #expect(errors.isEmpty)
    }

    // MARK: - Static-tier emission: three branches + fallback

    @Test("Three-branch emission carries a distinct data-gsel marker per branch")
    func emitsDistinctMarkersPerBranch() {
        let view = GeometrySelector {
            WidthCase(..<600) { Text("Narrow") }
            WidthCase(600..<900) { Text("Medium") }
            WidthCase(900...) { Text("Wide") }
        }
        let html = StaticHTMLRenderer.render(view, context: "Test").html

        // All three branches are present in the static-tier DOM.
        #expect(html.contains("Narrow"))
        #expect(html.contains("Medium"))
        #expect(html.contains("Wide"))

        // Count only DOM attributes (` data-gsel="…"`), not the CSS
        // attribute-selector occurrences of the same marker text inside the
        // registered gating stylesheet (`[data-gsel="…"]`).
        let domMarkerCount =
            html.matches(of: try! Regex(" data-gsel=\"[^\"]*\"")).count
        #expect(domMarkerCount == 3)
    }

    @Test("Each ranged branch hides itself under the NEGATION of its own at-rule")
    func gatingRuleHidesOwnBranchOutsideItsRange() {
        // Each branch hides OUTSIDE its own range — not "hidden by a
        // neighbor's own at-rule" — because that's the only shape that
        // still hides a branch correctly inside a GAP no branch's own
        // range covers (see fallbackIsTheOnlyVisibleBranchInsideAGap,
        // browser-verified as a real bug in an earlier version of this
        // method: nothing fired in the gap under the neighbor-hides scheme).
        let view = GeometrySelector {
            WidthCase(..<600) { Text("Narrow") }
            WidthCase(600..<900) { Text("Medium") }
            WidthCase(900...) { Text("Wide") }
        }
        let html = StaticHTMLRenderer.render(view, context: "Test").html

        #expect(html.contains("@media not (max-width: 599.98px)"))
        #expect(html.contains("@media not ((min-width: 600px) and (max-width: 899.98px))"))
        #expect(html.contains("@media not (min-width: 900px)"))
    }

    @Test("A bounded range's negation groups the whole conjunction in parens")
    func negatedBoundedRangeGroupsWholeConjunction() {
        // Browser-verified (headless Chrome): "not (min-width: 600px) and
        // (max-width: 899.98px)" WITHOUT the extra parens never matches at
        // ANY width — `not` binds to only the first feature per the Media
        // Queries L4 grammar, silently parsing as `not(A) and B` rather
        // than the intended `not(A and B)`. The whole conjunction must be
        // explicitly grouped: "not ((min-width: 600px) and (max-width:
        // 899.98px))".
        let range = WidthRange(600..<900)
        #expect(range.negatedCSSFeatures == "not ((min-width: 600px) and (max-width: 899.98px))")
    }

    @Test("A single-bound range's negation needs no extra grouping")
    func negatedSingleBoundRangeNeedsNoExtraParens() {
        #expect(WidthRange(600...).negatedCSSFeatures == "not (min-width: 600px)")
        #expect(WidthRange(..<600).negatedCSSFeatures == "not (max-width: 599.98px)")
    }

    @Test("A gap covered by a fallback hides the fallback under every other branch's at-rule")
    func fallbackHidesUnderEveryOtherBranch() {
        let view = GeometrySelector {
            WidthCase(..<600) { Text("Narrow") }
            WidthCase(900...) { Text("Wide") }
            GeometryFallback { Text("Middle") }
        }
        let html = StaticHTMLRenderer.render(view, context: "Test").html

        #expect(html.contains("Middle"))

        // The fallback's marker value: find it via the emitted markup.
        guard
            let fallbackMarkerRange = html.range(
                of: "data-gsel=\"[^\"]*\"(?=[^<]*Middle)",
                options: .regularExpression
            )
        else {
            Issue.record("Couldn't find the fallback's marker")
            return
        }
        let fallbackMarkerAttribute = String(html[fallbackMarkerRange])
        let fallbackMarkerValue = fallbackMarkerAttribute
            .replacingOccurrences(of: "data-gsel=\"", with: "")
            .replacingOccurrences(of: "\"", with: "")

        // The fallback's own hide-rule must appear under BOTH other branches'
        // at-rules — never a computed complement, per the ratified design.
        let narrowHidesFallback =
            html.range(
                of:
                "@media \\(max-width: 599\\.98px\\) \\{ \\[data-gsel=\"\\Q\(fallbackMarkerValue)\\E\"\\]",
                options: .regularExpression
            ) != nil
        let wideHidesFallback =
            html.range(
                of:
                "@media \\(min-width: 900px\\) \\{ \\[data-gsel=\"\\Q\(fallbackMarkerValue)\\E\"\\]",
                options: .regularExpression
            ) != nil

        #expect(narrowHidesFallback)
        #expect(wideHidesFallback)
    }

    // MARK: - Cascade ordering

    @Test("The gating rule is registered after the interned stylesheet")
    func gatingRuleFollowsInternedStylesheet() {
        let view = VStack {
            Text("Padded").padding(16)
            GeometrySelector {
                WidthCase(..<600) { Text("Narrow") }
                WidthCase(600...) { Text("Wide") }
            }
        }
        let html = StaticHTMLRenderer.render(view, context: "Test").html

        guard let internedRange = html.range(of: "scui-"),
              let mediaRange = html.range(of: "@media")
        else {
            Issue.record("Expected both an interned class and a gating @media rule")
            return
        }
        #expect(internedRange.lowerBound < mediaRange.lowerBound)
    }

    // MARK: - Container queries

    @Test(".container(_:) registers inline-size containment CSS")
    func containerModifierRegistersContainment() {
        let view = VStack {
            Text("Panel")
        }
        .container("sidebar")
        let html = StaticHTMLRenderer.render(view, context: "Test").html

        #expect(html.contains("container-type: inline-size"))
        #expect(html.contains("container-name: sidebar"))
        #expect(html.contains("data-gsel-container=\"sidebar\""))
    }

    @Test("A container-scoped GeometrySelector compiles to @container at-rules")
    func containerSelectorCompilesToContainerAtRules() {
        let view = VStack {
            Text("Label")
            GeometrySelector(of: "sidebar") {
                WidthCase(..<400) { Text("Stacked") }
                WidthCase(400...) { Text("Side by side") }
            }
        }
        .container("sidebar")
        let html = StaticHTMLRenderer.render(view, context: "Test").html

        #expect(html.contains("@container sidebar not (max-width: 399.98px)"))
        #expect(html.contains("@container sidebar not (min-width: 400px)"))
        #expect(!html.contains("@media not (max-width: 399.98px)"))
    }

    // MARK: - Gap regression (a real bug, browser-verified and fixed)

    @Test(
        "Inside a gap, the fallback is the ONLY visible branch — regular branches self-hide there too"
    )
    func fallbackIsTheOnlyVisibleBranchInsideAGap() {
        // An earlier version of registerGatingCSS hid each ranged branch
        // only under ITS SIBLINGS' own at-rules ("hidden by a neighbor"),
        // which is correct when ranges are gap-free but leaves a ranged
        // branch with NOTHING to hide it inside a gap — no sibling's own
        // at-rule fires there. Verified wrong in a real browser (headless
        // Chrome): all three branches showed display:block simultaneously
        // at a gap-region viewport width. The fix hides each ranged branch
        // under the NEGATION of its own range instead, which correctly
        // fires everywhere outside that range, gap included.
        let view = GeometrySelector {
            WidthCase(..<600) { Text("Narrow") }
            WidthCase(900...) { Text("Wide") }
            GeometryFallback { Text("Fallback") }
        }
        let html = StaticHTMLRenderer.render(view, context: "Test").html

        // Inside the 600..<900 gap, BOTH ranged branches must be hidden —
        // not just the fallback's own hide-rules under their at-rules, but
        // the ranged branches' own self-negation rules covering the gap.
        #expect(html.contains("@media not (max-width: 599.98px)"))
        #expect(html.contains("@media not (min-width: 900px)"))
    }

    // MARK: - Measuring tier (DummyBackend, not StaticHTMLBackend)

    /// Lays a view out under `DummyBackend` at a controlled proposed width,
    /// mirroring `StackLayoutTests.committedNode` — the standard pattern in
    /// this suite for a non-static-HTML backend where `htmlFragmentRegistry`
    /// is `nil`, exercising `GeometrySelector`'s measuring-tier arm.
    @MainActor
    private func committedNode<V: View>(
        for view: V,
        proposedSize: ProposedViewSize
    ) -> ViewGraphNode<V, DummyBackend> {
        let backend = DummyBackend()
        let window = backend.createWindow(withDefaultSize: nil, id: "window")
        let environment = EnvironmentValues(backend: backend).with(\.window, window)
        let node = ViewGraphNode(for: view, backend: backend, environment: environment)
        _ = node.computeLayout(proposedSize: proposedSize, environment: environment)
        _ = node.commit()
        return node
    }

    /// Finds every `DummyBackend.TextView` under a widget, depth-first.
    private func textViews(under widget: DummyBackend.Widget) -> [DummyBackend.TextView] {
        var found: [DummyBackend.TextView] = []
        if let textView = widget as? DummyBackend.TextView {
            found.append(textView)
        }
        for child in widget.getChildren() {
            found += textViews(under: child)
        }
        return found
    }

    @Test("Under a measuring tier, exactly one branch is instantiated — not all of them")
    func measuringTierInstantiatesOneBranch() {
        let view = GeometrySelector {
            WidthCase(..<600) { Text("Narrow") }
            WidthCase(600...) { Text("Wide") }
        }
        let node = committedNode(for: view, proposedSize: ProposedViewSize(300, 200))

        let texts = textViews(under: node.widget).map(\.content)
        #expect(texts == ["Narrow"])
    }

    @Test("The measuring tier picks the branch whose range contains the proposed width")
    func measuringTierPicksBranchMatchingProposedWidth() {
        let view = GeometrySelector {
            WidthCase(..<600) { Text("Narrow") }
            WidthCase(600...) { Text("Wide") }
        }

        let narrowNode = committedNode(for: view, proposedSize: ProposedViewSize(300, 200))
        #expect(textViews(under: narrowNode.widget).map(\.content) == ["Narrow"])

        let wideNode = committedNode(for: view, proposedSize: ProposedViewSize(800, 200))
        #expect(textViews(under: wideNode.widget).map(\.content) == ["Wide"])
    }

    @Test("On the measuring tier, a container-scoped selector falls through to its fallback")
    func measuringTierContainerSelectorUsesFallback() {
        // GeometryProxy has no notion of a named ancestor container (only the
        // size its immediate parent proposed), so .containerWidth conditions
        // are unanswerable on a measuring tier — the documented gap on
        // GeometrySelector.Condition.containerWidth. The selector falls
        // through to its fallback rather than guessing.
        let view = GeometrySelector(of: "sidebar") {
            WidthCase(..<400) { Text("Stacked") }
            WidthCase(400...) { Text("Side by side") }
            GeometryFallback { Text("Fallback") }
        }
        let node = committedNode(for: view, proposedSize: ProposedViewSize(800, 200))

        let texts = textViews(under: node.widget).map(\.content)
        #expect(texts == ["Fallback"])
    }

    @Test("No data-gsel markers or gating CSS exist on a measuring tier")
    func measuringTierEmitsNoStaticMachinery() {
        // htmlAttributes/.container's htmlHeadItem are both StaticHTMLBackend
        // environment-registry no-ops under any other backend (documented on
        // both modifiers) — this asserts that portability contract holds for
        // GeometrySelector's own emission, not just the modifiers it's built
        // from: nothing GeometrySelector does should require a registry to
        // exist under a measuring tier.
        let view = GeometrySelector {
            WidthCase(..<600) { Text("Narrow") }
            WidthCase(600...) { Text("Wide") }
        }
        // No throw/crash constructing or laying this out under DummyBackend,
        // where htmlFragmentRegistry is never seeded, is itself the
        // assertion — reaching the line below proves it.
        _ = committedNode(for: view, proposedSize: ProposedViewSize(300, 200))
    }

    // MARK: - Condition both-halves (unit level, no rendering)

    @Test("A viewport condition matches a measured width against its range")
    func viewportConditionMatchesMeasuredWidth() {
        let condition = GeometrySelector.Condition.viewportWidth(WidthRange(600..<900))
        #expect(!condition.matches(measuredWidth: 599))
        #expect(condition.matches(measuredWidth: 600))
        #expect(condition.matches(measuredWidth: 899))
        #expect(!condition.matches(measuredWidth: 900))
    }

    @Test("A container condition never matches on the measuring tier (documented gap)")
    func containerConditionNeverMatchesOnMeasuringTier() {
        let condition = GeometrySelector.Condition.containerWidth(
            name: "sidebar",
            range: WidthRange(400...)
        )
        #expect(!condition.matches(measuredWidth: 1000))
    }

    @Test("WidthRange.overlaps treats two same-direction unbounded ranges as overlapping")
    func overlapsHandlesUnboundedRanges() {
        #expect(WidthRange(600...).overlaps(WidthRange(900...)))
        #expect(!WidthRange(..<600).overlaps(WidthRange(600...)))
        #expect(WidthRange(..<700).overlaps(WidthRange(600...)))
    }
}
