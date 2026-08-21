import Testing

import Foundation
import StaticHTMLBackend
@_spi(Backends) import SwiftCrossUI
import SwiftCrossUIComponents

@Suite("Testing greedy-fill propagation through surviving wrapper elements")
struct GreedyFillPropagationTests {
    @MainActor
    @Test("A bare Slider fills its leading-aligned stack directly")
    func bareSliderFillsStackDirectly() {
        // Control case: no modifier sits between the stack and the input, so
        // the leaf's own width:100% is what has to carry the fill — nothing
        // else could.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .leading) {
                Slider(value: Self.box(0.5), in: 0.0...1.0)
            },
            context: "Bare slider"
        ).html

        guard
            let stackLine = html.split(separator: "\n").first(where: {
                $0.contains(#"data-scui="VStack""#)
            }),
            let inputLine = html.split(separator: "\n").first(where: { $0.contains("<input") })
        else {
            Issue.record("Expected both a VStack element and an input element")
            return
        }

        #expect(stackLine.contains("<input") == false)
        let rule = Self.internedRule(forClassOn: String(inputLine), in: html)
        #expect(rule?.contains("width:100%") == true)
    }

    @MainActor
    @Test("Padded, colored Slider fill propagation (known issue)")
    func paddedSliderFillPropagationKnownIssue() {
        // The defect this suite pins: .foregroundColor(.gray).padding() on a
        // Slider inside VStack(alignment: .leading) renders the slider at
        // its natural ~100px width in a browser, not filling the stack, even
        // though SwiftCrossUI's own layout system commits it at full width
        // (1180x10 for a 1200-wide proposal against DummyBackend). The
        // surviving PaddingModifierView and EnvironmentModifier wrappers
        // between the stack and the <input> carry only padding/flex-trio
        // declarations, none of which is a fill declaration, so the leaf's
        // width:100% resolves against their shrink-wrapped box instead of
        // the stack's.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .leading) {
                Slider(value: Self.box(0.5), in: 0.0...1.0)
                    .foregroundColor(.gray)
                    .padding()
            },
            context: "Padded slider"
        ).html

        let lines = html.split(separator: "\n").map(String.init)
        guard
            let stackIndex = lines.firstIndex(where: { $0.contains(#"data-scui="VStack""#) }),
            let inputIndex = lines.firstIndex(where: { $0.contains("<input") }),
            stackIndex < inputIndex
        else {
            Issue.record("Expected a VStack ancestor line before the input element")
            return
        }

        // Every div strictly between the stack and the input is an
        // intermediate wrapper. The fix (deferred) will make fill propagate
        // through each of them; its exact declaration is undecided, so any
        // of these three spellings satisfies it.
        let fillMarkers = ["align-self:stretch", "width:100%", "flex-grow"]
        let wrapperLines = lines[(stackIndex + 1)..<inputIndex].filter { $0.contains("<div") }

        #expect(!wrapperLines.isEmpty, "Expected at least one intermediate wrapper div")

        withKnownIssue(
            "Fill doesn't yet propagate through surviving wrappers — deferred to the elision-redesign wave"
        ) {
            for wrapperLine in wrapperLines {
                let rule = Self.internedRule(forClassOn: wrapperLine, in: html)
                let carriesFill = fillMarkers.contains { marker in
                    rule?.contains(marker) == true
                }
                #expect(carriesFill, "Wrapper line carries no fill declaration: \(wrapperLine)")
            }
        }
    }

    /// Mutable storage backing a ``box(_:)`` binding.
    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// A binding backed by a mutable box, so a control that requires one can
    /// be constructed for a one-shot render without an owning `@State`.
    private static func box<Value>(_ initial: Value) -> Binding<Value> {
        let storage = Box(initial)
        return Binding(get: { storage.value }, set: { storage.value = $0 })
    }

    /// The interned style rule for the class referenced on an element's own
    /// line, by reading its `class` attribute and looking up the matching
    /// `.scui-N { … }` rule in the stylesheet.
    private static func internedRule(forClassOn elementLine: String, in html: String) -> String? {
        guard let classRange = elementLine.range(of: "class=\"") else {
            return nil
        }
        let afterClass = elementLine[classRange.upperBound...]
        guard let closingQuote = afterClass.firstIndex(of: "\"") else {
            return nil
        }
        // Multiple class tokens can share one line (an author-added token
        // rides after the interned one), so only the first token — the
        // interned class — is the lookup key.
        let className = String(afterClass[..<closingQuote]).split(separator: " ").first
            .map(String.init)
        guard let className else {
            return nil
        }
        return html.split(separator: "\n").first { $0.contains(".\(className) {") }.map(String.init)
    }
}
