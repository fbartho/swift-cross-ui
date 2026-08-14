import Testing

import DummyBackend
import StaticHTMLBackend
@_spi(Backends) import SwiftCrossUI
import SwiftCrossUIComponents

@Suite("Testing escape-hatch consumption in the static HTML backend")
struct StaticHTMLEscapeHatchTests {
    @MainActor
    @Test("Two consumers share an inherited href while a third overrides it")
    func canonicalHrefConsumption() {
        let result = StaticHTMLRenderer.render(
            VStack {
                Button("One") {}
                VStack {
                    Button("Two") {}
                }
                Button("Three") {}.href("./bar")
            }
            .href("./foo"),
            context: "Canonical href"
        )

        #expect(result.html.components(separatedBy: "href=\"./foo\"").count - 1 == 2)
        #expect(result.html.components(separatedBy: "href=\"./bar\"").count - 1 == 1)
        // No container became a link, so every anchor is a button's own.
        #expect(result.html.components(separatedBy: "<a ").count - 1 == 3)
        #expect(result.documentInfo.hrefsWithoutConsumer.isEmpty)
    }

    @MainActor
    @Test("Each ForEach-generated button keeps its own href and attributes")
    func forEachGeneratedConsumersKeepTheirOwnValues() {
        for items in [["one"], ["one", "two", "three"]] {
            let result = StaticHTMLRenderer.render(
                HStack {
                    ForEach(items, id: \.self) { item in
                        Button {} label: {
                            Rectangle().frame(width: 16, height: 16)
                        }
                        .href("/\(item)")
                        .htmlAttributes(["data-item": .set(item)])
                    }
                },
                context: "ForEach links"
            )

            for item in items {
                #expect(result.html.contains("href=\"/\(item)\""))
                #expect(result.html.contains("data-item=\"\(item)\""))
            }
            #expect(result.html.components(separatedBy: "<a ").count - 1 == items.count)
            #expect(!result.html.contains("aria-disabled=\"true\""))
            #expect(result.documentInfo.hrefsWithoutConsumer.isEmpty)
        }
    }

    @MainActor
    @Test("ForEach-generated links stay per-item under any stack")
    func forEachGeneratedConsumersSurviveEveryStack() {
        let items = ["one", "two", "three"]
        func links() -> some View {
            ForEach(items, id: \.self) { item in
                Button {} label: {
                    Rectangle().frame(width: 16, height: 16)
                }
                .href("/\(item)")
            }
        }

        let vertical = StaticHTMLRenderer.render(
            VStack { links() },
            context: "VStack links"
        ).html
        let layered = StaticHTMLRenderer.render(
            ZStack { links() },
            context: "ZStack links"
        ).html

        for html in [vertical, layered] {
            for item in items {
                #expect(html.contains("href=\"/\(item)\""))
            }
            #expect(html.components(separatedBy: "<a ").count - 1 == items.count)
        }
    }

    @MainActor
    @Test("An href over plain text reaches no consumer and is reported")
    func hrefWithNoConsumerIsDiagnosed() {
        let result = StaticHTMLRenderer.render(
            VStack {
                Text("First")
                Text("Second")
            }
            .href("/nowhere"),
            context: "No consumer"
        )

        #expect(!result.html.contains("<a "))
        #expect(!result.html.contains("href=\"/nowhere\""))
        #expect(result.documentInfo.hrefsWithoutConsumer == ["/nowhere"])
    }

    @MainActor
    @Test("An id materializes its wrapper and lands there exactly once")
    func identifiedAttributesMaterializeTheirWrapper() {
        let html = StaticHTMLRenderer.render(
            VStack {
                VStack {
                    Text("Only")
                }
                .htmlAttributes(["id": "x"])
            },
            context: "Identified wrapper"
        ).html

        #expect(html.components(separatedBy: "id=\"x\"").count - 1 == 1)
        // The id sits on the wrapper's own element, not on the text inside it.
        #expect(!html.contains("id=\"x\" class=\"scui-0\" data-scui=\"Text\""))
        #expect(html.contains(">Only</span>"))
    }

    @MainActor
    @Test("An id on an element-emitting view lands on that element, not a wrapper")
    func identifiedAttributesAttachToTheViewsOwnElement() {
        // Materialization vetoes elision of an existing container; it never
        // generates one. A Button emits a real element, so the id belongs on
        // it — a wrapper minted just to carry the id would put the name on a
        // box the author never wrote.
        let html = StaticHTMLRenderer.render(
            Button("Press") {}.href("/go").htmlAttributes(["id": "foo"]),
            context: "Identified button"
        ).html

        #expect(html.components(separatedBy: "id=\"foo\"").count - 1 == 1)
        guard let range = html.range(of: "<[^>]*id=\"foo\"[^>]*>", options: .regularExpression)
        else {
            Issue.record("Expected an element carrying the id")
            return
        }
        // The id's element is the button's own live anchor, not a div.
        #expect(html[range].hasPrefix("<a "))
        #expect(html[range].contains("href=\"/go\""))
    }

    @MainActor
    @Test("An attribute block with no id rides through an elided wrapper")
    func unidentifiedAttributesRideThroughElision() {
        let html = StaticHTMLRenderer.render(
            VStack {
                VStack {
                    Text("Only")
                }
                .htmlAttributes(["aria-label": "Nav"])
            },
            context: "Elided wrapper"
        ).html

        #expect(html.components(separatedBy: "aria-label=\"Nav\"").count - 1 == 1)
        #expect(html.contains("aria-label=\"Nav\""))
        #expect(html.contains(">Only</span>"))
    }

    @MainActor
    @Test("A mixed block materializes as one unit")
    func mixedAttributeBlockMaterializesTogether() {
        let html = StaticHTMLRenderer.render(
            VStack {
                VStack {
                    Text("Only")
                }
                .htmlAttributes(["id": "x", "aria-label": "Nav"])
            },
            context: "Mixed block"
        ).html

        #expect(html.components(separatedBy: "id=\"x\"").count - 1 == 1)
        #expect(html.components(separatedBy: "aria-label=\"Nav\"").count - 1 == 1)
        // One block, one element: both keys land on the same tag.
        guard let range = html.range(of: "<[^>]*id=\"x\"[^>]*>", options: .regularExpression) else {
            Issue.record("Expected an element carrying the id")
            return
        }
        #expect(html[range].contains("aria-label=\"Nav\""))
    }

    @MainActor
    @Test("A consumed href does not leak into the consumer's label subtree")
    func consumingAnHrefClearsItForTheLabel() {
        let result = StaticHTMLRenderer.render(
            HStack {
                Button {} label: {
                    Rectangle().frame(width: 16, height: 16)
                }
                .href("/icon")
            },
            context: "Clear on consume"
        )

        // Exactly one element carries the destination: the control itself.
        #expect(result.html.components(separatedBy: "href=\"/icon\"").count - 1 == 1)
        #expect(result.html.components(separatedBy: "<a ").count - 1 == 1)
        #expect(result.documentInfo.hrefsWithoutConsumer.isEmpty)
    }

    @MainActor
    @Test("An inner href overrides only for the consumer that carries it")
    func innerHrefOverridesForItsConsumerOnly() {
        let result = StaticHTMLRenderer.render(
            VStack {
                Button("Outer") {}
                Button("Inner") {}.href("./inner")
            }
            .href("./outer"),
            context: "Inner override"
        )

        #expect(result.html.contains("href=\"./outer\">Outer</a>"))
        #expect(result.html.contains("href=\"./inner\">Inner</a>"))
        #expect(result.documentInfo.hrefsWithoutConsumer.isEmpty)
    }

    @MainActor
    @Test("A tag names one element, not each of the views it covers")
    func htmlTagNamesExactlyOneElement() {
        let html = StaticHTMLRenderer.render(
            VStack {
                VStack {
                    Text("First")
                    Text("Second")
                }
                .htmlTag(.section)
            },
            context: "Tagged wrapper"
        ).html

        // The stack the author tagged becomes the section; its children keep
        // their own elements rather than each becoming one.
        #expect(html.components(separatedBy: "<section").count - 1 == 1)
        #expect(html.contains(">First</span>"))
        #expect(html.contains(">Second</span>"))
    }

    @MainActor
    @Test("A tag survives on a wrapper that would otherwise be dropped")
    func htmlTagKeepsAnOtherwiseElidableWrapper() {
        // A single-child stack carrying nothing is dropped as an empty
        // wrapper. Naming an element is a request for that element to exist,
        // so the tag has to reach the document either way.
        let html = StaticHTMLRenderer.render(
            VStack {
                VStack {
                    Text("Only")
                }
                .htmlTag(.section)
            },
            context: "Elidable tagged wrapper"
        ).html

        #expect(html.components(separatedBy: "<section").count - 1 == 1)
        #expect(html.contains(">Only</"))
    }

    @MainActor
    @Test("Under a backend that can't capture, the modifiers are plain wrappers")
    func captureDegradesToAPassThroughWrapper() {
        // The capture is a conditional conformance check, so a backend that
        // doesn't answer it renders the content unchanged rather than
        // trapping — which is what keeps a tree carrying these modifiers
        // portable.
        let backend = DummyBackend()
        let window = backend.createWindow(withDefaultSize: nil, id: "window")
        let environment = EnvironmentValues(backend: backend).with(\.window, window)

        let plain = ViewGraphNode(
            for: Text("Only"),
            backend: backend,
            environment: environment
        )
        let modified = ViewGraphNode(
            for: Text("Only")
                .htmlTag(.section)
                .htmlAttributes(["id": "x", "aria-label": "Nav"]),
            backend: backend,
            environment: environment
        )

        let plainSize = plain.computeLayout(proposedSize: .unspecified, environment: environment)
        _ = plain.commit()
        let modifiedSize = modified.computeLayout(
            proposedSize: .unspecified,
            environment: environment
        )
        _ = modified.commit()

        #expect(modifiedSize.size == plainSize.size)
    }
}
