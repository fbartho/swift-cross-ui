import Testing

import Foundation
import StaticHTMLBackend
@_spi(Backends) import SwiftCrossUI
import SwiftCrossUIComponents

@Suite("Testing context-inheritance mode for the static HTML backend")
struct StaticHTMLInheritModeTests {
    @MainActor
    @Test("A context-passing wrapper is described as arranging nothing")
    func contextWrapperWritesNoTrio() {
        // An environment modifier forwards to a single-child body, which the
        // layout system describes as a stack like any other. The flex trio
        // that description would produce is what changes a child's sizing, so
        // an element that only carries a value writes none of it.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .leading) {
                Text("Only").environment(\.font, .body).frame(width: 200, height: 50)
            },
            context: "Context wrapper"
        ).html

        let wrapper = Self.elementLine(taggedWith: "EnvironmentModifier", in: html)
        #expect(wrapper != nil)
        #expect(Self.internedRule(forClassOn: wrapper ?? "", in: html) == nil)
    }

    @MainActor
    @Test("An erased view's holder arranges nothing either")
    func anyViewWritesNoTrio() {
        // `AnyView`'s container holds the erased child at the origin and takes
        // its size, so the arrangement its stack description implies is
        // incidental in exactly the way an environment modifier's is.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .leading) {
                AnyView(Text("Erased")).frame(width: 200, height: 50)
            },
            context: "Erased view"
        ).html

        let wrapper = Self.elementLine(taggedWith: "AnyView", in: html)
        #expect(wrapper != nil)
        #expect(Self.internedRule(forClassOn: wrapper ?? "", in: html) == nil)
    }

    @MainActor
    @Test("A multi-child stack under a context modifier keeps arranging its children")
    func contextModifierOverMultiChildStackKeepsTrio() {
        // Inherit mode speaks for the container the modifier itself produces.
        // A stack of two or more children genuinely places them against each
        // other, so its own description stands whatever wraps it.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .leading) {
                HStack {
                    Text("One")
                    Text("Two")
                }
                .environment(\.font, .body)
            },
            context: "Context over stack"
        ).html

        let stack = Self.elementLine(taggedWith: "HStack", in: html)
        let rule = Self.internedRule(forClassOn: stack ?? "", in: html)
        #expect(rule?.contains("display:flex") == true)
        #expect(rule?.contains("flex-direction:row") == true)
        #expect(rule?.contains("align-items:center") == true)
    }

    @MainActor
    @Test("A frame attached to a context modifier still pins the element")
    func attachedFrameStillPins() {
        // Self-declaration says this view has no presentational intent of its
        // own; it cannot say none was attached from outside. A frame lands on
        // the widget inherit mode also describes, and the frame wins.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .leading) {
                Text("Only").environment(\.font, .body).frame(width: 200, height: 50)
            },
            context: "Attached frame"
        ).html

        let rule = Self.internedRule(containing: "width:200px", in: html)
        #expect(rule?.contains("height:50px") == true)
    }

    @MainActor
    @Test("An infinite-stretch frame attached to a context modifier still relays")
    func attachedInfiniteStretchStillRelays() {
        // `.environment(…).frame(maxWidth: .infinity)` is the greedy-fill
        // idiom applied over a context wrapper. The stretch has to reach the
        // element, since nothing below it declares a width.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .leading) {
                Text("Only").environment(\.font, .body).frame(maxWidth: .infinity)
            },
            context: "Attached stretch"
        ).html

        let wrapper = Self.elementLine(taggedWith: "EnvironmentModifier", in: html)
        let rule = Self.internedRule(forClassOn: wrapper ?? "", in: html)
        #expect(rule?.contains("align-self:stretch") == true)
    }

    @MainActor
    @Test("A stretching descendant is relayed through a context wrapper")
    func stretchRelaysThroughContextWrapper() {
        // The relay guard reads the child chain, so a context wrapper sitting
        // above a stretching descendant has to carry the same stretch or the
        // descendant fills only the wrapper's shrink-wrapped box.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .leading) {
                Text("Only").frame(maxWidth: .infinity).environment(\.font, .body)
            },
            context: "Relayed stretch"
        ).html

        let wrapper = Self.elementLine(taggedWith: "EnvironmentModifier", in: html)
        let rule = Self.internedRule(forClassOn: wrapper ?? "", in: html)
        #expect(rule?.contains("align-self:stretch") == true)
        #expect(rule?.contains("flex-grow:1") == true)
    }

    /// The first element line carrying a `data-scui` identity.
    private static func elementLine(taggedWith tag: String, in html: String) -> String? {
        html.split(separator: "\n").first { $0.contains("data-scui=\"\(tag)\"") }.map(String.init)
    }

    /// The first stylesheet rule containing a marker.
    private static func internedRule(containing marker: String, in html: String) -> String? {
        html.split(separator: "\n").first { $0.contains(marker) }.map(String.init)
    }

    /// The interned style rule for the class referenced on an element's own
    /// line, or `nil` where the element carries no class at all.
    private static func internedRule(forClassOn elementLine: String, in html: String) -> String? {
        guard let classRange = elementLine.range(of: "class=\"") else {
            return nil
        }
        let afterClass = elementLine[classRange.upperBound...]
        guard let closingQuote = afterClass.firstIndex(of: "\"") else {
            return nil
        }
        // An author-added token can ride after the interned one, so only the
        // first token is the lookup key.
        guard
            let className = String(afterClass[..<closingQuote]).split(separator: " ").first
            .map(String.init)
        else {
            return nil
        }
        return html.split(separator: "\n").first { $0.contains(".\(className) {") }
            .map(String.init)
    }
}
