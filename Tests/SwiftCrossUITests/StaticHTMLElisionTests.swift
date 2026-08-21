import Testing

import Foundation
import StaticHTMLBackend
@_spi(Backends) import SwiftCrossUI
import SwiftCrossUIComponents

/// A guide whose default sits a fifth of the way down — far enough from centre
/// that emitting it as centre would be visible.
enum EmissionFifthAlignmentID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> Double {
        context.height / 5
    }
}

extension VerticalAlignment {
    static let emissionFifth = VerticalAlignment(EmissionFifthAlignmentID.self)
}

@Suite("Testing wrapper elision for the static HTML backend")
struct StaticHTMLElisionTests {
    @MainActor
    @Test("A wrapper carrying nothing but the flex trio is spliced away")
    func inertWrapperIsElided() {
        // Group adds a container the author never asked for. With one child,
        // a leading alignment, and no styling of its own, it writes
        // display/flex-direction/align-items and nothing else — declarations
        // that describe how to arrange children this element does not have
        // more than one of.
        //
        // The parent's alignment is what makes the child's flex trio inert:
        // .leading is the placement block flow already gives, so the wrapper's
        // own align-items:flex-start does no work.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .leading) {
                Group {
                    Text("Only")
                }
            },
            context: "Inert wrapper"
        ).html

        #expect(html.contains("Only"))
        #expect(!html.contains("data-scui=\"Group\""))
    }

    @MainActor
    @Test("A centering stack of several children survives, since it places them")
    func centeringWrapperSurvives() {
        // align-items genuinely distributes two or more items within this
        // element's own box. At one child the box shrink-wraps and the same
        // declaration has no slack to work in, so only the multi-child case
        // is real work.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .leading) {
                VStack(alignment: .center) {
                    Text("One")
                    Text("Two")
                }
            },
            context: "Centering wrapper"
        ).html

        let rule = Self.internedRule(containing: "align-items:center", in: html)
        #expect(rule != nil)
    }

    @MainActor
    @Test("A single-child wrapper under a centering parent is elided")
    func centeredParentSingleChildWrapperIsElided() {
        // The wrapper inherits the default center alignment rather than
        // declaring one, and at one child its own align-items has no slack to
        // place the child within — only the parent's alignment decides the
        // child's box, and a stack alignment can never say stretch.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .center) {
                Group {
                    Text("Only")
                }
            },
            context: "Centered parent"
        ).html

        #expect(html.contains("Only"))
        #expect(!html.contains("data-scui=\"Group\""))
    }

    @MainActor
    @Test("A single-child wrapper under a trailing parent is elided")
    func trailingParentSingleChildWrapperIsElided() {
        // .trailing maps to flex-end, which is as inert at one child as
        // center: the shrink-wrapped wrapper has no cross-axis slack either
        // way.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .trailing) {
                Group {
                    Text("Only")
                }
            },
            context: "Trailing parent"
        ).html

        #expect(html.contains("Only"))
        #expect(!html.contains("data-scui=\"Group\""))
    }

    @MainActor
    @Test("A wrapper is single-child independently of its parent's child count")
    func oneChildWrapperInsideTwoChildStackIsElided() {
        // The stack has two children and keeps its element; the wrapper
        // around the first has one and goes. The elision question is asked of
        // each container about its own children.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .center) {
                Group {
                    Text("Alpha")
                }
                Text("Beta")
            },
            context: "Two-child stack"
        ).html

        #expect(html.contains("data-scui=\"VStack\""))
        #expect(!html.contains("data-scui=\"Group\""))
    }

    @MainActor
    @Test("A custom guide emits the edge nearest its line, not a blanket center")
    func customGuideEmitsItsNearestEdge() {
        // The description a custom guide reaches this backend as carries where
        // its line sits, so the fallback tracks the guide instead of collapsing
        // every custom alignment onto center. A guide a fifth of the way down
        // is nearest the leading edge, and flex-start is what says so.
        let html = StaticHTMLRenderer.render(
            HStack(alignment: .emissionFifth) {
                Text("One")
                Text("Two")
            },
            context: "Custom guide fallback"
        ).html

        #expect(Self.internedRule(containing: "align-items:flex-start", in: html) != nil)
        #expect(Self.internedRule(containing: "align-items:center", in: html) == nil)
    }

    @MainActor
    @Test("No stack alignment can produce align-items:stretch")
    func stackAlignmentNeverProducesStretch() {
        // The single-child elision law rests on stretch being unreachable
        // from a stack's alignment: a stretching parent is the one case where
        // the wrapper would be load-bearing. Every alignment reaches CSS
        // through StackAlignmentEdge — custom guides included, via
        // `closestEdge` — so this switch is where the law lives. It is
        // exhaustive so that a fourth edge fails compilation here and points at
        // the law before it silently breaks.
        func probe(_ edge: StackAlignmentEdge) -> (stack: HorizontalAlignment, css: String) {
            switch edge {
                case .leading: (.leading, "flex-start")
                case .center: (.center, "center")
                case .trailing: (.trailing, "flex-end")
            }
        }

        for alignment in [StackAlignmentEdge.leading, .center, .trailing] {
            let (stackAlignment, expectedCSS) = probe(alignment)
            let html = StaticHTMLRenderer.render(
                VStack(alignment: stackAlignment) {
                    Text("One")
                    Text("Two")
                },
                context: "Alignment mapping"
            ).html

            #expect(
                Self.internedRule(
                    containing: "align-items:\(expectedCSS)",
                    in: html
                ) != nil
            )
            #expect(Self.internedRule(containing: "align-items:stretch", in: html) == nil)
        }
    }

    @MainActor
    @Test("No emitted rule selects through one interned class to another")
    func noCombinatorsOverInternedClasses() {
        // Elision is safe against the stylesheet because no selector can
        // depend on a structural wrapper's presence: every interned rule
        // names exactly one class. A combinator between two interned classes
        // would break that property, so its absence is pinned here.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .center) {
                Group {
                    Text("Alpha")
                }
                HStack {
                    Text("Beta")
                    Text("Gamma")
                }
            },
            context: "Combinator guard"
        ).html

        let combinator = html.range(
            of: #"\.scui-[0-9a-z]+[^{,\n]*[ >+~][^{,\n]*\.scui-"#,
            options: .regularExpression
        )
        #expect(combinator == nil)
    }

    @MainActor
    @Test("A wrapper under a block parent is elided like any other")
    func inertWrapperUnderBlockParentIsElided() {
        // What made a wrapper's fate depend on its parent's formatting context
        // was the flex trio: a flex item sizes to content on the cross axis
        // where a block box fills, and an inline child is blockified as a flex
        // item but not as a block box. A wrapper that arranges nothing writes
        // none of that, and an element with no declarations measures
        // byte-identical to no element under a block parent as much as under a
        // flex one.
        let html = StaticHTMLRenderer.render(
            Group {
                Text("Root child")
            },
            context: "Block parent"
        ).html

        #expect(html.contains("Root child"))
        #expect(!html.contains("data-scui=\"Group\""))
    }

    @MainActor
    @Test("A wrapper over a percentage-width child survives, since it is the box")
    func wrapperOverPercentageWidthChildSurvives() {
        // A `width:100%` leaf resolves against whichever ancestor survives, so
        // this wrapper is what its percentage means. Splicing it away
        // re-resolves the width against a different box — measured at 133px
        // with the wrapper against 1200px without it.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .leading) {
                Group {
                    Slider(Binding<Double>?.none, minimum: 0.0, maximum: 1.0)
                }
            },
            context: "Percentage child"
        ).html

        #expect(html.contains("data-scui=\"Group\""))
        #expect(html.contains("<input"))
    }

    @MainActor
    @Test("A spacer survives elision, keeping the flex shorthand that is its whole effect")
    func spacerSurvives() {
        // A Spacer is an empty container: it holds no children to splice into
        // its place, and its `flex:1 1 0%` is the entirety of what it does —
        // an element with no content whose only output is a declaration is
        // the opposite of the inert wrapper elision removes. The shorthand is
        // asserted exactly, since a spacer surviving without it would occupy
        // no space at all.
        let between = StaticHTMLRenderer.render(
            HStack {
                Text("Left")
                Spacer()
                Text("Right")
            },
            context: "Spacer between",
            size: SIMD2(600, 200)
        ).html

        let spacer = Self.elementLine(taggedWith: "Spacer", in: between)
        #expect(spacer != nil)
        #expect(
            Self.internedRule(forClassOn: spacer ?? "", in: between)?
                .contains("flex:1 1 0%") == true
        )

        // A lone spacer's stack is itself elidable, leaving the spacer as the
        // only element under the root — it still survives and still carries
        // the shorthand.
        let alone = StaticHTMLRenderer.render(
            VStack {
                Spacer()
            },
            context: "Lone spacer",
            size: SIMD2(600, 200)
        ).html

        let loneSpacer = Self.elementLine(taggedWith: "Spacer", in: alone)
        #expect(loneSpacer != nil)
        #expect(
            Self.internedRule(forClassOn: loneSpacer ?? "", in: alone)?
                .contains("flex:1 1 0%") == true
        )
    }

    @MainActor
    @Test("A multi-child stack is never elided, so flex item counts are preserved")
    func multiChildStackSurvives() {
        // Two children make this a real flex container: its items are laid out
        // against each other, and removing it would hand them to a different
        // container with a different axis, spacing, and alignment.
        let html = StaticHTMLRenderer.render(
            VStack {
                HStack {
                    Text("One")
                    Text("Two")
                }
            },
            context: "Multi-child"
        ).html

        #expect(html.contains("data-scui=\"HStack\""))
    }

    @MainActor
    @Test("A wrapper the author tagged or attributed survives")
    func authoredWrapperSurvives() {
        // An element the author named is function by definition, whatever its
        // style turns out to be.
        let tagged = StaticHTMLRenderer.render(
            VStack {
                Group {
                    Text("Tagged")
                }
                .htmlTag(.custom("section"))
            },
            context: "Tagged wrapper"
        ).html
        let attributed = StaticHTMLRenderer.render(
            VStack {
                Group {
                    Text("Attributed")
                }
                .htmlAttributes(["aria-label": "Region"])
            },
            context: "Attributed wrapper"
        ).html

        #expect(tagged.contains("<section"))
        #expect(attributed.contains("aria-label=\"Region\""))
    }

    @MainActor
    @Test("Elision never rewrites the whitespace inside a pre")
    func preservesSignificantWhitespace() {
        // Whitespace inside a `<pre>` is content. The decision runs before the
        // children are emitted so they are built at the depth they end up at;
        // re-indenting finished markup would strip leading spaces from every
        // line of a code sample and silently change what the page says.
        let sample = "    indented\n        deeper\n"
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .leading) {
                Group {
                    Text(sample).htmlTag(.custom("pre"))
                }
            },
            context: "Pre whitespace"
        ).html

        #expect(html.contains(sample))
    }

    @MainActor
    @Test("A split view's panes and their subtrees survive elision")
    func splitViewPanesSurvive() {
        // The panes are landmark elements the backend introduces rather than
        // the view tree, so nothing about them is elidable — and their content
        // still reaches the document.
        let html = StaticHTMLRenderer.render(
            NavigationSplitView {
                Text("Sidebar item")
            } detail: {
                Text("Detail body")
            },
            context: "SplitView elision",
            size: SIMD2(900, 600)
        ).html

        #expect(html.contains("<nav"))
        #expect(html.contains("<main"))
        #expect(html.contains("Sidebar item"))
        #expect(html.contains("Detail body"))
    }

    @MainActor
    @Test("A ZStack's overlapping children keep their pinned coordinates")
    func overlappingChildrenSurvive() {
        // Overlap is the one arrangement flow has no rule for, so those
        // children are positioned absolutely — a placement that writes real
        // coordinates, which elision refuses.
        let html = StaticHTMLRenderer.render(
            ZStack {
                Color.red.frame(width: 100, height: 100)
                Text("Over")
            },
            context: "ZStack elision",
            size: SIMD2(400, 400)
        ).html

        #expect(html.contains("position:absolute"))
        #expect(html.contains("Over"))
    }

    @MainActor
    @Test("A scroll container survives, since its overflow is what makes it one")
    func scrollContainerSurvives() {
        let html = StaticHTMLRenderer.render(
            ScrollView {
                Text("Scrolled body")
            },
            context: "ScrollView elision",
            size: SIMD2(400, 200)
        ).html

        #expect(Self.internedRule(containing: "overflow:auto", in: html) != nil)
        #expect(html.contains("Scrolled body"))
    }

    @MainActor
    @Test("A raw fragment's wrapper keeps display:contents rather than being elided")
    func rawFragmentWrapperSurvives() {
        // Both display:contents and elision remove a box, but they answer
        // different questions: the wrapper on the way to a fragment leaf has a
        // committed 0x0 size that describes nothing real, and it has to stay in
        // the DOM for the fragment's markup to land in the right place.
        let html = StaticHTMLRenderer.render(
            VStack {
                HTMLRawFragment("<em>raw</em>")
            },
            context: "Raw fragment elision"
        ).html

        #expect(html.contains("<em>raw</em>"))
        #expect(Self.internedRule(containing: "display:contents", in: html) != nil)
    }

    @MainActor
    @Test("Elision leaves the rendered text of a document byte-identical")
    func textIsUnchanged() {
        // The property that makes elision safe to apply everywhere: it removes
        // elements, never content. This is what would have caught the
        // re-indentation bug immediately rather than through a confusing width
        // difference several layers away.
        let view = VStack(alignment: .leading) {
            Group {
                Text("Alpha")
            }
            HStack {
                Text("Beta")
                Text("Gamma")
            }
        }
        let html = StaticHTMLRenderer.render(view, context: "Text identity").html

        for word in ["Alpha", "Beta", "Gamma"] {
            #expect(Self.count(of: word, in: html) == 1)
        }
    }

    /// The first stylesheet rule containing a marker.
    private static func internedRule(containing marker: String, in html: String) -> String? {
        html.split(separator: "\n").first { $0.contains(marker) }.map(String.init)
    }

    /// The first element line carrying a `data-scui` identity.
    private static func elementLine(taggedWith tag: String, in html: String) -> String? {
        html.split(separator: "\n").first { $0.contains("data-scui=\"\(tag)\"") }.map(String.init)
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

    /// How many times a substring occurs in a document.
    private static func count(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
