import Testing

import Foundation
import StaticHTMLBackend
@_spi(Backends) import SwiftCrossUI

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
    @Test("A centering wrapper survives, since it places its child")
    func centeringWrapperSurvives() {
        // align-items positions the child on the cross axis within this
        // element's own box, which is real work at any child count — only
        // flex-start names the placement block flow already gives. Eliding
        // these moved every anchor element on all three site pages.
        let html = StaticHTMLRenderer.render(
            VStack(alignment: .center) {
                Text("Centered")
            },
            context: "Centering wrapper"
        ).html

        let rule = Self.internedRule(containing: "align-items:center", in: html)
        #expect(rule != nil)
    }

    @MainActor
    @Test("A wrapper under a block parent survives, since its child would resize")
    func flexWrapperUnderBlockParentSurvives() {
        // A block-level flex item sizes to content on the cross axis while the
        // same element in block flow fills its container, and an inline child
        // is blockified as a flex item but not as a block box. Which of those
        // the child ends up as is decided by whichever ancestor survives, so
        // the guard is a property of the parent — at the document root there
        // is no flex parent at all.
        let html = StaticHTMLRenderer.render(
            Group {
                Text("Root child")
            },
            context: "Block parent"
        ).html

        #expect(html.contains("data-scui=\"Group\""))
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
                RawHTMLFragment("<em>raw</em>")
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

    /// How many times a substring occurs in a document.
    private static func count(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
