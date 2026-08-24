import Testing

import DummyBackend
import StaticHTMLBackend
@_spi(Backends) import SwiftCrossUI
import SwiftCrossUIComponents

@Suite("Testing TextGroup inline runs")
struct TextGroupTests {
    /// The markup inside `#root`, which is where a view's own output lands.
    @MainActor
    static func body(of html: String) -> String {
        let afterRoot = html.components(separatedBy: "<div id=\"root\">")[1]
        return afterRoot.components(separatedBy: "\n</div>")[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    @Test("Runs emit inside one element with no whitespace between them")
    func runsShareOneElementWithoutWhitespace() {
        let result = StaticHTMLRenderer.render(
            TextGroup {
                Text("This is ")
                TextRun("Bold").emphasized()
                Text(" and ")
                TextRun("italic").italic()
                Text("!")
            }
            .htmlTag(.p),
            context: "Runs"
        )

        let body = Self.body(of: result.html)
        // The whole point of the group: a reader copying it gets one
        // uninterrupted string, which any whitespace between runs would break.
        #expect(
            body.contains(
                ">This is <strong class=\"scui-0\">Bold</strong> and "
                    + "<em class=\"scui-1\">italic</em>!</p>"
            )
        )
        #expect(body.components(separatedBy: "<p").count - 1 == 1)
    }

    @MainActor
    @Test("A run states only the intent it carries")
    func runsCarryOnlyTheirOwnIntent() {
        let result = StaticHTMLRenderer.render(
            TextGroup {
                Text("plain")
                TextRun("strong").emphasized()
                TextRun("emphasis").italic()
            }
            .htmlTag(.p),
            context: "Intents"
        )

        let body = Self.body(of: result.html)
        // A run asking for nothing is a bare text node, not a span standing
        // for no declaration.
        #expect(body.contains(">plain<strong"))
        #expect(body.contains("<strong class=\"scui-0\">strong</strong>"))
        #expect(body.contains("<em class=\"scui-1\">emphasis</em>"))
        #expect(!body.contains("<span"))
        #expect(result.html.contains(".scui-0 { font-weight:bolder }"))
        #expect(result.html.contains(".scui-1 { font-style:italic }"))
    }

    @MainActor
    @Test("An emphasized run steps up from whatever weight the group resolves to")
    func emphasisComposesWithTheGroupsWeight() {
        let result = StaticHTMLRenderer.render(
            TextGroup {
                Text("A ")
                TextRun("bold").emphasized()
            }
            .font(.title)
            .htmlTag(.h2),
            context: "Weight"
        )

        // `bolder` rather than a literal: the group's own weight is a custom
        // property a page may redefine, and a literal equal to that value
        // would render the emphasis invisible.
        #expect(result.html.contains(".scui-0 { font-weight:bolder }"))
        #expect(!result.html.contains("font-weight:700"))
    }

    @MainActor
    @Test("A run that overrides its style carries that style, keeping its intent tag")
    func styleOverridesAreOrthogonalToIntent() {
        let result = StaticHTMLRenderer.render(
            TextGroup {
                Text("normal ")
                TextRun("smaller").font(.footnote)
                TextRun("bold and smaller").font(.footnote).emphasized()
            }
            .font(.body)
            .htmlTag(.p),
            context: "Overrides"
        )

        let body = Self.body(of: result.html)
        // A style override alone is a span; the same override under an intent
        // keeps the intent's element and carries the style on it.
        #expect(body.contains("<span class=\"scui-0\">smaller</span>"))
        #expect(body.contains("<strong class=\"scui-1\">bold and smaller</strong>"))
        #expect(result.html.contains("font-size:var(--scui-fs-footnote)"))
    }

    @MainActor
    @Test("A run that overrides nothing inherits the group's scale")
    func unstyledRunsInheritTheGroupsScale() {
        let result = StaticHTMLRenderer.render(
            TextGroup {
                Text("A ")
                TextRun("bold").emphasized()
                Text(" word")
            }
            .font(.title)
            .htmlTag(.h2),
            context: "Scale"
        )

        // Size and line height live on the group's own class, so every run
        // steps down together at a compact width.
        #expect(result.html.contains("font-size:var(--scui-fs-title)"))
        #expect(!result.html.contains(".scui-0 { font-size"))
    }

    @MainActor
    @Test("A bare text style derives one heading for the whole group")
    func aBareStyleDerivesOneHeadingForTheGroup() {
        let result = StaticHTMLRenderer.render(
            TextGroup {
                Text("Plain ")
                TextRun("Bold").emphasized()
            }
            .font(.title),
            context: "Heading"
        )

        let body = Self.body(of: result.html)
        #expect(body.components(separatedBy: "<h2").count - 1 == 1)
        // Runs never derive elements of their own, so nothing nests inside.
        #expect(body.components(separatedBy: "<h").count - 1 == 1)
        #expect(result.documentInfo.headings.count == 1)
        #expect(result.documentInfo.headings.first?.level == 2)
        #expect(result.documentInfo.headings.first?.text == "Plain Bold")
    }

    @MainActor
    @Test("An explicit tag outranks the style's derived heading")
    func explicitTagWinsElementSelection() {
        let result = StaticHTMLRenderer.render(
            TextGroup {
                Text("Plain ")
                TextRun("Bold").emphasized()
            }
            .font(.title)
            .htmlTag(.p),
            context: "Explicit"
        )

        let body = Self.body(of: result.html)
        #expect(body.hasPrefix("<p"))
        #expect(!body.contains("<h2"))
    }

    @MainActor
    @Test("A group with no style and no tag emits a span")
    func theDefaultElementIsASpan() {
        let result = StaticHTMLRenderer.render(
            VStack {
                TextGroup {
                    Text("Plain ")
                    TextRun("Bold").emphasized()
                }
            },
            context: "Default"
        )

        // `<span>`, not `<p>`: a paragraph cannot nest inside a paragraph, so
        // a block default would make a nested group invalid markup.
        #expect(Self.body(of: result.html).contains("<span class="))
    }

    @MainActor
    @Test("A group's markup matches an ordinary Text of the same combined string")
    func aGroupMatchesTheOrdinaryParagraphItStandsInFor() {
        let group = StaticHTMLRenderer.render(
            TextGroup {
                Text("One ")
                TextRun("two").emphasized()
                Text(" three")
            }
            .htmlTag(.p),
            context: "Parity"
        )
        let ordinary = StaticHTMLRenderer.render(
            Text("One two three").htmlTag(.p),
            context: "Parity"
        )

        // Same characters in the same order, so a reader copying either gets
        // the same string — the reason the group emits one element.
        #expect(Self.plainText(of: Self.body(of: group.html)) == "One two three")
        #expect(Self.plainText(of: Self.body(of: ordinary.html)) == "One two three")
    }

    /// The text a reader would copy, with every tag removed.
    @MainActor
    static func plainText(of markup: String) -> String {
        var text = ""
        var insideTag = false
        for character in markup {
            switch character {
                case "<": insideTag = true
                case ">": insideTag = false
                default: if !insideTag { text.append(character) }
            }
        }
        return text
    }

    @MainActor
    @Test("A backend with no inline-run support renders the flattened text")
    func nonWebBackendsFlattenTheGroup() {
        let backend = DummyBackend()
        let window = backend.createWindow(withDefaultSize: nil, id: "window")
        let environment = EnvironmentValues(backend: backend).with(\.window, window)
        let node = ViewGraphNode(
            for: TextGroup {
                Text("One ")
                TextRun("two").emphasized()
                Text(" three")
            },
            backend: backend,
            environment: environment
        )
        _ = node.computeLayout(proposedSize: .unspecified, environment: environment)
        _ = node.commit()

        func text(in widget: DummyBackend.Widget) -> String? {
            if let text = widget as? DummyBackend.TextView {
                return text.content
            }
            return widget.getChildren().lazy.compactMap(text(in:)).first
        }

        // The fail-safe: every character reaches a backend that never reads
        // the runs, with only the per-run emphasis dropped.
        #expect(text(in: node.widget) == "One two three")
    }

    @Test("Runs merge only where their intents match")
    func adjacentRunsMergeOnMatchingIntents() {
        let text = AttributedText(runs: [
            AttributedText.Run("one "),
            AttributedText.Run("two"),
            AttributedText.Run("bold", intents: [.stronglyEmphasized]),
            AttributedText.Run("er", intents: [.stronglyEmphasized]),
            AttributedText.Run(""),
            AttributedText.Run(" tail"),
        ])

        #expect(text.runs.count == 3)
        #expect(text.runs[0].text == "one two")
        #expect(text.runs[1].text == "bolder")
        #expect(text.runs[1].intents == [.stronglyEmphasized])
        #expect(text.runs[2].text == " tail")
        #expect(text.plainText == "one twobolder tail")
    }

    @MainActor
    @Test("A group built from attributed text emits the same runs")
    func attributedTextRoundTripsThroughAGroup() {
        let result = StaticHTMLRenderer.render(
            TextGroup(
                AttributedText(runs: [
                    AttributedText.Run("plain "),
                    AttributedText.Run("bold", intents: [.stronglyEmphasized]),
                    AttributedText.Run(" and "),
                    AttributedText.Run("italic", intents: [.emphasized]),
                ])
            )
            .htmlTag(.p),
            context: "Attributed"
        )

        let body = Self.body(of: result.html)
        #expect(body.contains(">plain <strong"))
        #expect(body.contains("<em class=\"scui-1\">italic</em>"))
    }
}
