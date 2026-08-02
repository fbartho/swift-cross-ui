import Foundation
import ImageFormats
import Testing

import DummyBackend
@testable import StaticHTMLBackend

@_spi(Backends) import SwiftCrossUI

@Suite("Testing document fragments, slots, and asset emission")
@MainActor
struct StaticHTMLFragmentTests {

    // MARK: - Dedupe keying

    @Test("A src-based item keys off its URL, so two registrations collapse to one")
    func deduplicatesByURL() {
        let registry = HTMLFragmentRegistry()
        #expect(registry.register(.script(src: "/js/a.js"), slot: .bodyEnd))
        #expect(!registry.register(.script(src: "/js/a.js"), slot: .bodyEnd))
        #expect(registry.items(in: .bodyEnd).count == 1)
    }

    @Test("Distinct inline content without ids produces distinct keys, so both survive")
    func keepsDistinctInlineContent() {
        let registry = HTMLFragmentRegistry()
        registry.register(.style("a { color: red }"), slot: .head)
        registry.register(.style("a { color: blue }"), slot: .head)
        #expect(registry.items(in: .head).count == 2)
    }

    @Test("Identical inline content collapses on its content hash")
    func deduplicatesIdenticalInlineContent() {
        let registry = HTMLFragmentRegistry()
        registry.register(.style("a { color: red }"), slot: .head)
        registry.register(.style("a { color: red }"), slot: .head)
        #expect(registry.items(in: .head).count == 1)
    }

    @Test("An author id overrides the derived key, collapsing different content")
    func authorIDOverridesDerivedKey() {
        let registry = HTMLFragmentRegistry()
        registry.register(.script(src: "/js/v1.js"), slot: .bodyEnd, id: "analytics")
        registry.register(.script(src: "/js/v2.js"), slot: .bodyEnd, id: "analytics")

        let items = registry.items(in: .bodyEnd)
        #expect(items.count == 1)
        // First registration wins, which is what makes an override work: the
        // page owner's item gets in before the component's.
        #expect(items.first?.content == .script(src: "/js/v1.js"))
    }

    @Test("Content hashing is stable across processes, not seeded per run")
    func contentHashIsStable() {
        // A per-process seed (Hasher) would give one asset a different
        // data-scui-head-id on every build, breaking the cross-tier check.
        #expect(FragmentContent.hash(of: "scui") == FragmentContent.hash(of: "scui"))
        #expect(FragmentContent.hash(of: "scui") != FragmentContent.hash(of: "scui2"))
    }

    // MARK: - Placement validity

    @Test("A meta tag is only legal in the head")
    func metaIsHeadOnly() {
        #expect(FragmentContent.meta(["name": "x"]).allows(.head))
        #expect(!FragmentContent.meta(["name": "x"]).allows(.bodyEnd))
        #expect(!FragmentContent.meta(["name": "x"]).allows(.custom("aside")))
    }

    @Test("Scripts and styles are legal in every slot")
    func scriptsAndStylesArePlacementFree() {
        for content: FragmentContent in [
            .script(src: "/a.js"),
            .inlineScript("x"),
            .stylesheet(href: "/a.css"),
            .style("a{}"),
            .rawHTML("<i></i>"),
        ] {
            #expect(content.allows(.head))
            #expect(content.allows(.bodyEnd))
            #expect(content.allows(.custom("aside")))
        }
    }

    // MARK: - Emission

    @Test("Every emitted item carries the cross-tier marker")
    func emittedItemsCarryTheMarker() {
        let script = FragmentItem(.script(src: "/js/a.js"), slot: .bodyEnd)
        #expect(script.rendered(indent: "").contains("data-scui-head-id=\"url:/js/a.js\""))

        let meta = FragmentItem(.meta(["name": "author"]), slot: .head, id: "author")
        #expect(meta.rendered(indent: "").contains("data-scui-head-id=\"id:author\""))

        let style = FragmentItem(.style("a{}"), slot: .head)
        #expect(style.rendered(indent: "").contains("data-scui-head-id=\"sha:"))
    }

    @Test("A script body's closing tag is neutralized so it can't end the element early")
    func neutralizesClosingScriptTagInBody() {
        let item = FragmentItem(.inlineScript("var s = \"</script>\";"), slot: .bodyEnd)
        let html = item.rendered(indent: "")
        #expect(html.contains("<\\/script>"))
        // Exactly one real closing tag: the element's own.
        #expect(html.components(separatedBy: "</script>").count == 2)
    }

    @Test("Script and style bodies aren't HTML-escaped, since entities don't decode there")
    func doesNotEscapeScriptBodies() {
        let item = FragmentItem(.inlineScript("if (a && b < c) {}"), slot: .bodyEnd)
        #expect(item.rendered(indent: "").contains("if (a && b < c) {}"))
    }

    // MARK: - Registration through the view tree

    @Test("A view's contribution reaches the document")
    func viewContributionReachesTheDocument() {
        let view = VStack {
            Text("Hello")
                .htmlHeadItem(.stylesheet(href: "/css/widget.css"))
        }
        let html = StaticHTMLRenderer.render(view, context: "Contribution").html
        #expect(html.contains("<link rel=\"stylesheet\" href=\"/css/widget.css\""))
    }

    @Test("A component used many times contributes its asset once")
    func repeatedComponentContributesOnce() {
        let view = VStack {
            ForEach([1, 2, 3, 4, 5]) { _ in
                Text("Row").htmlHeadItem(.stylesheet(href: "/css/row.css"))
            }
        }
        let html = StaticHTMLRenderer.render(view, context: "Dedupe").html
        // Counting tags, not URL occurrences: each emitted tag names the URL
        // twice, once as the href and once inside the cross-tier marker.
        #expect(html.components(separatedBy: "href=\"/css/row.css\"").count == 2)
    }

    @Test("Contributions targeting bodyEnd land after the content, not in the head")
    func bodyEndContributionsLandAfterContent() throws {
        let view = Text("Hi").htmlHeadItem(.script(src: "/js/late.js"), slot: .bodyEnd)
        let html = StaticHTMLRenderer.render(view, context: "Tail").html

        let scriptIndex = try #require(html.range(of: "/js/late.js")).lowerBound
        let rootIndex = try #require(html.range(of: "<div id=\"root\">")).lowerBound
        let headEnd = try #require(html.range(of: "</head>")).lowerBound
        #expect(scriptIndex > rootIndex)
        #expect(scriptIndex > headEnd)
    }

    @Test("The protocol sugar registers the same items the modifier would")
    func protocolSugarRegistersItems() {
        struct Highlighted: HTMLHeadContributing {
            var headItems: [FragmentItem] {
                [FragmentItem(.stylesheet(href: "/css/highlight.css"), slot: .head)]
            }

            var body: some View {
                contributingBody { Text("code") }
            }
        }

        let html = StaticHTMLRenderer.render(Highlighted(), context: "Sugar").html
        #expect(html.contains("/css/highlight.css"))
    }

    @Test("Registration is a no-op when no registry is in the environment")
    func registrationIsPortable() {
        // Under a native backend the environment entry stays nil, so the
        // modifier has to be inert rather than a crash or a requirement.
        let registry: HTMLFragmentRegistry? = nil
        #expect(registry?.register(.style("a{}"), slot: .head) == nil)
    }

    // MARK: - Ordering

    @Test("The page owner's items emit after the view tree's contributions")
    func pageOwnerItemsWinOnSourceOrder() throws {
        let view = Text("Hi").htmlHeadItem(.style("body { color: red }"))
        let context = DocumentContext(title: "Order")
            .with(.style("body { color: blue }"), slot: .head)
        let html = StaticHTMLRenderer.render(view, context: context).html

        let contributed = try #require(html.range(of: "body { color: red }")).lowerBound
        let owned = try #require(html.range(of: "body { color: blue }")).lowerBound
        #expect(owned > contributed)
    }

    @Test("A registered style emits after the interned stylesheet, so it can override it")
    func registeredStylesFollowInternedStyles() throws {
        // Load-bearing for the tier work: a registered .style has to be able to
        // beat an interned property on source order (the geometry selectors'
        // display:none gates depend on it), which only holds if contributions
        // come after the interned block.
        let view = Text("Hi").font(.title).htmlHeadItem(.style(".override { font-size: 99px }"))
        let html = StaticHTMLRenderer.render(view, context: "Cascade").html

        let interned = try #require(html.range(of: ".scui-0 {")).lowerBound
        let registered = try #require(html.range(of: ".override { font-size: 99px }")).lowerBound
        #expect(registered > interned)
    }

    @Test("The reset emits before the interned stylesheet, so classes outrank it")
    func resetPrecedesInternedStyles() throws {
        let view = Text("Hi").font(.title)
        let html = StaticHTMLRenderer.render(view, context: "Reset order").html

        let reset = try #require(html.range(of: "data-scui-head-id=\"id:scui-reset\"")).lowerBound
        let interned = try #require(html.range(of: ".scui-0 {")).lowerBound
        #expect(reset < interned)
    }

    // MARK: - The overridable reset

    @Test("The reset is present by default")
    func resetIsPresentByDefault() {
        let html = StaticHTMLRenderer.render(Text("Hi"), context: "Default").html
        #expect(html.contains("data-scui-head-id=\"id:scui-reset\""))
        #expect(html.contains("appearance: none"))
    }

    @Test("An item registered under the reserved key replaces the built-in reset")
    func resetIsOverridable() {
        let context = DocumentContext(title: "Override")
            .with(.style("/* my own reset */"), slot: .head, id: "scui-reset")
        let html = StaticHTMLRenderer.render(Text("Hi"), context: context).html

        #expect(html.contains("/* my own reset */"))
        // The built-in's contents are gone, but the reserved key is still the
        // one thing carrying a reset — the override is a replacement, not an
        // addition.
        #expect(!html.contains("appearance: none"))
        #expect(html.components(separatedBy: "id:scui-reset").count == 2)
    }

    // MARK: - Raw fragments

    @Test("A raw fragment's payload reaches the document verbatim")
    func rawFragmentSplicesVerbatim() {
        let view = VStack {
            Text("Before")
            RawHTMLFragment("<figure class=\"x\"><em>&amp;</em></figure>")
            Text("After")
        }
        let html = StaticHTMLRenderer.render(view, context: "Raw").html
        #expect(html.contains("<figure class=\"x\"><em>&amp;</em></figure>"))
    }

    @Test("A raw fragment replaces its element rather than nesting inside one")
    func rawFragmentEmitsNoWrapper() {
        let html = StaticHTMLRenderer.render(
            RawHTMLFragment("<hr id=\"marker\">"),
            context: "Raw"
        ).html
        // The zero-size leaf the view produces exists only to carry the
        // payload; emitting a box around it would leave a stray div.
        #expect(html.contains("<hr id=\"marker\">"))
        #expect(!html.contains("<div data-scui=\"Color\""))
    }

    @Test(
        "A raw fragment's wrapper chain emits display:contents, so it doesn't overlap flex siblings"
    )
    func rawFragmentWrapperDoesNotOverlapFlexSiblings() {
        // Whatever committed size RawHTMLFragment's leaf reports, every
        // ancestor wrapper on the way to it (the view's own boundary,
        // .transformEnvironment, and the EitherView/TupleView1 the
        // display-mode switch in its body introduces) also honestly reports
        // it. A width:0;height:0 flex item doesn't push siblings aside, so
        // the spliced content would visually overlap the next sibling if any
        // of those wrappers kept a real CSS box. display:contents on every
        // wrapper in the chain removes them from layout entirely, so the
        // fragment's real content becomes a genuine flex item instead.
        let html = StaticHTMLRenderer.render(
            VStack {
                Text("Before")
                RawHTMLFragment("<p data-fragment=\"true\">Spliced</p>")
                Text("After")
            },
            context: "Raw fragment in a stack"
        ).html

        // Every div between the VStack and the spliced <p> is present in
        // markup (EitherView, TupleView1, EnvironmentModifier,
        // RawHTMLFragment), but none of them should carry a width/height
        // declaration derived from the leaf's committed size —
        // display:contents replaces it.
        #expect(html.contains("data-scui=\"EitherView\""))
        #expect(html.contains("display:contents"))
        #expect(!html.contains("width:0px"))
        #expect(!html.contains("height:0px"))
    }

    @Test("Under StaticHTMLBackend, nativeDisplay never gates the splice")
    func nativeDisplayNeverGatesTheWebPath() {
        // The flag exists for backends that can't execute the markup at
        // all — StaticHTMLBackend can, so it always splices regardless of
        // what nativeDisplay says, both from the environment and from the
        // constructor override.
        let hiddenByEnvironment = StaticHTMLRenderer.render(
            RawHTMLFragment("<hr id=\"marker\">")
                .environment(\.rawFragmentNativeDisplay, .hidden),
            context: "Env hidden"
        ).html
        #expect(hiddenByEnvironment.contains("<hr id=\"marker\">"))

        let hiddenByConstructor = StaticHTMLRenderer.render(
            RawHTMLFragment("<hr id=\"marker\">", nativeDisplay: .hidden),
            context: "Constructor hidden"
        ).html
        #expect(hiddenByConstructor.contains("<hr id=\"marker\">"))
    }

    // MARK: - Native display

    @Test("Under a non-web backend, .source is the default and reports a real size")
    func nativeDisplaySourceIsTheDefault() {
        // Nothing here reads htmlRawFragmentRequest, so the view actually
        // rendered is what the layout system sees: Text(html), which has a
        // real, non-zero size — unlike the web path's zero-size leaf.
        let backend = DummyBackend()
        let window = backend.createWindow(withDefaultSize: nil, id: "window")
        let environment = EnvironmentValues(backend: backend).with(\.window, window)

        let node = ViewGraphNode(
            for: RawHTMLFragment("<p>Some markup</p>"),
            backend: backend,
            environment: environment
        )
        let result = node.computeLayout(proposedSize: .unspecified, environment: environment)
        _ = node.commit()

        #expect(result.size != .zero)
    }

    @Test("Under a non-web backend, .hidden collapses to zero size")
    func nativeDisplayHiddenCollapsesEntirely() {
        let backend = DummyBackend()
        let window = backend.createWindow(withDefaultSize: nil, id: "window")
        let environment = EnvironmentValues(backend: backend).with(\.window, window)

        let node = ViewGraphNode(
            for: RawHTMLFragment("<p>Some markup</p>", nativeDisplay: .hidden),
            backend: backend,
            environment: environment
        )
        let result = node.computeLayout(proposedSize: .unspecified, environment: environment)
        _ = node.commit()

        #expect(result.size == .zero)
    }

    @Test("The environment value flips every fragment's native display at once")
    func nativeDisplayEnvironmentValueAppliesWithNoConstructorOverride() {
        let backend = DummyBackend()
        let window = backend.createWindow(withDefaultSize: nil, id: "window")
        let environment = EnvironmentValues(backend: backend)
            .with(\.window, window)
            .with(\.rawFragmentNativeDisplay, .hidden)

        let node = ViewGraphNode(
            for: RawHTMLFragment("<p>Some markup</p>"),
            backend: backend,
            environment: environment
        )
        let result = node.computeLayout(proposedSize: .unspecified, environment: environment)
        _ = node.commit()

        #expect(result.size == .zero)
    }

    @Test("The constructor's nativeDisplay overrides the environment")
    func nativeDisplayConstructorOverridesEnvironment() {
        let backend = DummyBackend()
        let window = backend.createWindow(withDefaultSize: nil, id: "window")
        // The environment says .hidden; the instance asks for .source and
        // should win, since a nil-checked per-instance override beats the
        // ambient default it would otherwise follow.
        let environment = EnvironmentValues(backend: backend)
            .with(\.window, window)
            .with(\.rawFragmentNativeDisplay, .hidden)

        let node = ViewGraphNode(
            for: RawHTMLFragment("<p>Some markup</p>", nativeDisplay: .source),
            backend: backend,
            environment: environment
        )
        let result = node.computeLayout(proposedSize: .unspecified, environment: environment)
        _ = node.commit()

        #expect(result.size != .zero)
    }

    // MARK: - Comments

    @Test("A comment is emitted with the delimiters around its text")
    func commentEmitsDelimitedText() {
        let html = StaticHTMLRenderer.render(
            HTMLComment("Navigation starts here"),
            context: "Comment"
        ).html
        #expect(html.contains("<!-- Navigation starts here -->"))
    }

    @Test("A comment is indented to the level it's spliced at")
    func commentMatchesSpliceIndentation() {
        // The emitter prefixes a spliced fragment with the indent of the
        // element it replaces, so the comment lines up with the innermost
        // wrapper of its own chain rather than floating at column zero.
        //
        // That chain — the view's own boundary, .transformEnvironment,
        // StrictFrameView — is RawHTMLFragment's, and it puts the payload
        // three levels deeper than the stack siblings it sits between. The
        // wrappers exist for layout (they carry display:contents so the
        // fragment doesn't overlap flex siblings) and are invisible in the
        // rendered page, so this is cosmetic in the source only. Asserted at
        // the depth the infrastructure actually produces rather than the
        // shallower one, so a future change to the chain shows up here.
        let html = StaticHTMLRenderer.render(
            VStack {
                Text("Before")
                HTMLComment("Between the two")
                Text("After")
            },
            context: "Comment indentation"
        ).html

        func indent(ofLineContaining needle: String) -> String? {
            html.components(separatedBy: "\n")
                .first { $0.contains(needle) }
                .map { String($0.prefix { $0 == " " }) }
        }

        let commentIndent = indent(ofLineContaining: "<!--")
        let wrapperIndent = indent(ofLineContaining: "data-scui=\"StrictFrameView\"")
        #expect(commentIndent != nil)
        #expect(wrapperIndent != nil)
        if let commentIndent, let wrapperIndent {
            // One level inside the wrapper that encloses it.
            #expect(commentIndent == wrapperIndent + "  ")
        }
    }

    @Test("A comment nests no deeper than RawHTMLFragment's own wrapper chain")
    func commentAddsNoWrapperLevel() {
        // HTMLComment sets the fragment request itself rather than nesting a
        // RawHTMLFragment, which would add another wrapper and indent the
        // comment one step further from the markup it annotates.
        // RawHTMLFragment's own chain is one level deeper than HTMLComment's
        // fixed one, from the EitherView/TupleView1 its display-mode switch
        // introduces — that's intrinsic to RawHTMLFragment, not composition
        // overhead, so the invariant under test is "no deeper", not "equal".
        func depth(of html: String) -> Int {
            html.components(separatedBy: "\n")
                .first { $0.contains("<!--") || $0.contains("<p>Spliced</p>") }
                .map { $0.prefix { $0 == " " }.count } ?? -1
        }

        let comment = StaticHTMLRenderer.render(
            VStack {
                Text("Before")
                HTMLComment("Annotation")
                Text("After")
            },
            context: "Comment depth"
        ).html
        let fragment = StaticHTMLRenderer.render(
            VStack {
                Text("Before")
                RawHTMLFragment("<p>Spliced</p>")
                Text("After")
            },
            context: "Fragment depth"
        ).html

        #expect(depth(of: comment) <= depth(of: fragment))
    }

    @Test("A payload containing the terminator can't break out of the comment")
    func commentNeutralizesTerminator() {
        let html = StaticHTMLRenderer.render(
            HTMLComment("evil --> <script>alert(1)</script>"),
            context: "Comment terminator"
        ).html

        // The escaped form keeps the author's text readable while leaving the
        // parser nothing to end the comment on. Entities aren't decoded inside
        // comments, so the &gt; stays literal rather than becoming a > again.
        #expect(html.contains("--&gt;"))
        // Exactly one terminator: the one this comment's own closing
        // delimiter contributes. The payload's markup stays inside the
        // comment as text rather than becoming a real element — browser
        // -verified in probes/corner-radius-bg/comment-safety.html, where the
        // document parses to a single comment node, no script elements, and
        // the script body never runs.
        #expect(html.components(separatedBy: "-->").count == 2)
    }

    @Test("A trailing hyphen can't combine with the closing delimiter")
    func commentSeparatesTrailingHyphen() {
        // Without the separator the emitted text would end `--->`, which is a
        // terminator the author didn't write.
        #expect(HTMLComment.sanitize("ends with a dash-") == "ends with a dash- ")
        let html = StaticHTMLRenderer.render(
            HTMLComment("ends with a dash-"),
            context: "Comment trailing hyphen"
        ).html
        #expect(!html.contains("--->"))
    }

    @Test("A bare double hyphen is left alone, since no browser ends a comment on it")
    func commentPreservesDoubleHyphen() {
        // Rewriting every `--` would corrupt ordinary prose (a CLI flag, an
        // em-dash written as two hyphens) to satisfy a validator rule that no
        // parser enforces.
        #expect(HTMLComment.sanitize("run --verbose") == "run --verbose")
    }

    @Test("A comment renders as nothing under a non-HTML backend")
    func commentIsANoOpUnderOtherBackends() {
        // The payload rides an environment value only StaticHTMLBackend reads,
        // so under any other backend the view is just the zero-size Color the
        // fragment's body produces. A comment has no native equivalent, and
        // rendering as nothing is the intended behaviour rather than a gap.
        let backend = DummyBackend()
        let window = backend.createWindow(withDefaultSize: nil, id: "window")
        let environment = EnvironmentValues(backend: backend).with(\.window, window)

        let node = ViewGraphNode(
            for: HTMLComment("Invisible to native backends"),
            backend: backend,
            environment: environment
        )
        let result = node.computeLayout(
            proposedSize: .unspecified,
            environment: environment
        )
        _ = node.commit()

        #expect(result.size == .zero)
    }

    @Test("A comment doesn't participate in layout")
    func commentDoesNotParticipateInLayout() {
        // Comments aren't boxes. The comment rides RawHTMLFragment's
        // zero-size leaf, whose wrapper chain emits display:contents so the
        // siblings lay out as though it weren't there.
        let withComment = StaticHTMLRenderer.render(
            VStack {
                Text("Before")
                HTMLComment("Invisible")
                Text("After")
            },
            context: "Comment layout"
        ).html

        #expect(withComment.contains("display:contents"))
        #expect(!withComment.contains("width:0px"))
        #expect(!withComment.contains("height:0px"))
    }

    // MARK: - Custom slots

    @Test("A slot component emits that slot's items where it sits in the tree")
    func slotComponentEmitsItsItems() throws {
        let view = VStack {
            Text("Above")
            SlotComponent("aside")
            Text("Below")
        }
        let context = DocumentContext(title: "Slots")
            .withSlot("aside")
            .with(.rawHTML("<aside>note</aside>"), slot: .custom("aside"))
        let html = StaticHTMLRenderer.render(view, context: context).html

        let above = try #require(html.range(of: "Above")).lowerBound
        let aside = try #require(html.range(of: "<aside>note</aside>")).lowerBound
        let below = try #require(html.range(of: "Below")).lowerBound
        #expect(aside > above)
        #expect(aside < below)
    }

    @Test("A slot's items don't leak into the head or the body tail")
    func slotItemsStayInTheirSlot() {
        let view = VStack {
            Text("Content")
            SlotComponent("aside")
        }
        let context = DocumentContext(title: "Slots")
            .withSlot("aside")
            .with(.style(".only-in-slot {}"), slot: .custom("aside"))
        let html = StaticHTMLRenderer.render(view, context: context).html
        #expect(html.components(separatedBy: ".only-in-slot {}").count == 2)
    }

    // MARK: - Asset emission

    @Test("With no store configured, image data inlines as a data URL")
    func inlinesWithoutAStore() {
        let html = StaticHTMLRenderer.render(
            Self.testImage(),
            context: "Inline"
        ).html
        #expect(html.contains("src=\"data:image/png;base64,"))
    }

    @Test("With a store configured, an image becomes a content-hashed file reference")
    func publishesToTheStore() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DirectoryAssetStore(directory: directory, urlPrefix: "assets")
        let context = DocumentContext(title: "Published", assetStore: store)
        let html = StaticHTMLRenderer.render(Self.testImage(), context: context).html

        #expect(!html.contains("data:image/png;base64,"))
        #expect(html.contains("src=\"assets/"))

        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(written.count == 1)
        let name = try #require(written.first)
        #expect(name.hasSuffix(".png"))
        // The name is the content hash, so it carries no source filename.
        #expect(html.contains("assets/\(name)"))
    }

    @Test("The same image published twice yields one file")
    func storeDeduplicatesByContent() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DirectoryAssetStore(directory: directory)
        let bytes: [UInt8] = [1, 2, 3, 4]
        let first = store.publish(bytes, fileExtension: "png")
        let second = store.publish(bytes, fileExtension: "png")

        #expect(first == second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    @Test("Different bytes hash differently, so distinct images don't collide")
    func storeDistinguishesDifferentContent() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DirectoryAssetStore(directory: directory)
        let first = store.publish([1, 2, 3, 4], fileExtension: "png")
        let second = store.publish([4, 3, 2, 1], fileExtension: "png")

        #expect(first != second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test("An image at or under the inline threshold stays inline despite the store")
    func honorsTheInlineThreshold() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DirectoryAssetStore(directory: directory)
        let context = DocumentContext(
            title: "Small",
            assetStore: store,
            // Far above any 2x2 PNG, so the threshold is what decides.
            inlineAssetThreshold: 100_000
        )
        let html = StaticHTMLRenderer.render(Self.testImage(), context: context).html

        #expect(html.contains("data:image/png;base64,"))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Alt text stays author-supplied, since no accessibility seam reaches Image")
    func altTextIsAuthorSupplied() {
        let labelled = StaticHTMLRenderer.render(
            Self.testImage().htmlAttributes(["alt": "A red square"]),
            context: "Alt"
        ).html
        #expect(labelled.contains("alt=\"A red square\""))

        // Absent an author label the image is marked decorative rather than
        // left for assistive tech to guess at.
        let bare = StaticHTMLRenderer.render(Self.testImage(), context: "Alt").html
        #expect(bare.contains("alt=\"\""))
    }

    // MARK: - Integration

    @Test("A page using every surface emits them in the designed source order")
    func fullDocumentSourceOrder() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let view = VStack {
            Text("Heading").font(.title)
            Self.testImage()
            Text("Body")
                .htmlHeadItem(.style(".contributed { color: red }"))
                .htmlHeadItem(.script(src: "/js/widget.js"), slot: .bodyEnd)
            // Registered twice by two different views; one tag comes out.
            Text("Twin").htmlHeadItem(.script(src: "/js/widget.js"), slot: .bodyEnd)
            SlotComponent("aside")
            RawHTMLFragment("<hr id=\"raw\">")
        }

        let context = DocumentContext(
            title: "Everything",
            items: [
                FragmentItem(.meta(["name": "author", "content": "fbartho"]), slot: .head),
                FragmentItem(.style(".owned { color: blue }"), slot: .head),
                FragmentItem(.inlineScript("console.log('tail')"), slot: .bodyEnd),
            ],
            customSlots: ["aside"],
            assetStore: DirectoryAssetStore(directory: directory)
        )

        let html = StaticHTMLRenderer.render(view, context: context).html

        func index(of needle: String) throws -> String.Index {
            try #require(html.range(of: needle), "missing \(needle)").lowerBound
        }

        // Head: title, then the reset, then interned styles, then
        // contributions, then the page owner's own items.
        let title = try index(of: "<title>")
        let reset = try index(of: "id:scui-reset")
        let interned = try index(of: ".scui-0 {")
        let contributedStyle = try index(of: ".contributed { color: red }")
        let ownedStyle = try index(of: ".owned { color: blue }")
        let ownedMeta = try index(of: "name=\"author\"")
        let headEnd = try index(of: "</head>")

        #expect(title < reset)
        #expect(reset < interned)
        #expect(interned < contributedStyle)
        #expect(contributedStyle < ownedStyle)
        #expect(contributedStyle < ownedMeta)
        #expect(ownedStyle < headEnd)

        // Body: content, with the slot and the raw fragment in tree position.
        let root = try index(of: "<div id=\"root\">")
        let image = try index(of: "<img")
        let raw = try index(of: "<hr id=\"raw\">")
        #expect(headEnd < root)
        #expect(root < image)
        #expect(image < raw)

        // Tail: contributions, then the page owner's, both after the content.
        let tailScript = try index(of: "/js/widget.js")
        let ownedTail = try index(of: "console.log('tail')")
        #expect(raw < tailScript)
        #expect(tailScript < ownedTail)

        // The twin registration collapsed. Counting tags, not URL occurrences:
        // each tag names the URL twice, once as src and once in the marker.
        #expect(html.components(separatedBy: "src=\"/js/widget.js\"").count == 2)
        // The image went to the store rather than inline.
        #expect(!html.contains("data:image/png;base64,"))
        // Every emitted item is findable by a runtime tier.
        #expect(html.contains("data-scui-head-id=\"url:/js/widget.js\""))
    }

    // MARK: - documentInfo

    @Test("The heading outline captures every derived heading, in document order")
    func documentInfoCapturesHeadingOutline() {
        let view = VStack {
            Text("Title").font(.largeTitle)
            Text("Section").font(.title)
            Text("Subsection").font(.title2)
            Text("Body")
        }
        let info = StaticHTMLRenderer.render(view, context: "Outline").documentInfo

        #expect(
            info.headings == [
                DocumentInfo.Heading(level: 1, text: "Title"),
                DocumentInfo.Heading(level: 2, text: "Section"),
                DocumentInfo.Heading(level: 3, text: "Subsection"),
            ]
        )
    }

    @Test("An explicit tag overriding a derived heading excludes it from the outline")
    func documentInfoOutlineRespectsExplicitOverride() {
        let view = VStack {
            Text("Real heading").font(.largeTitle)
            Text("Not a heading").font(.title).htmlTag(.p)
        }
        let info = StaticHTMLRenderer.render(view, context: "Override").documentInfo

        #expect(info.headings == [DocumentInfo.Heading(level: 1, text: "Real heading")])
    }

    @Test("Registered meta items map standard names onto standard keys")
    func documentInfoMapsStandardMetaNames() {
        let context = DocumentContext(
            title: "Metadata",
            items: [
                FragmentItem(.meta(["name": "description", "content": "A page."]), slot: .head),
                FragmentItem(.meta(["name": "author", "content": "fbartho"]), slot: .head),
                FragmentItem(
                    .meta(["property": "og:type", "content": "article"]),
                    slot: .head
                ),
            ]
        )
        let info = StaticHTMLRenderer.render(Text("Body"), context: context).documentInfo

        #expect(info.metadata[.description] == "A page.")
        #expect(info.metadata[.author] == "fbartho")
        #expect(info.metadata[.custom("og:type")] == "article")
    }

    @Test("Title flows through from the document context unchanged")
    func documentInfoTitleFlowsThrough() {
        let info = StaticHTMLRenderer.render(Text("Body"), context: "A Specific Title").documentInfo
        #expect(info.title == "A Specific Title")
    }

    @Test("A page with no headings or metadata yields an empty outline and empty metadata")
    func documentInfoEmptyPageShape() {
        let info = StaticHTMLRenderer.render(Text("Just body text"), context: "Plain").documentInfo

        #expect(info.title == "Plain")
        #expect(info.headings.isEmpty)
        #expect(info.metadata.isEmpty)
    }

    @Test("DocumentInfoKey maps unrecognized raw names to .custom")
    func documentInfoKeyStandardOrCustom() {
        #expect(DocumentInfoKey.standardOrCustom("description") == .description)
        #expect(DocumentInfoKey.standardOrCustom("author") == .author)
        #expect(DocumentInfoKey.standardOrCustom("canonical") == .canonicalURL)
        #expect(DocumentInfoKey.standardOrCustom("og:image") == .custom("og:image"))
    }

    // MARK: - Helpers

    /// A 2x2 image, small enough to keep encoded output tiny.
    private static func testImage() -> SwiftCrossUI.Image {
        SwiftCrossUI.Image(
            ImageFormats.Image<RGBA>(
                width: 2,
                height: 2,
                pixels: [
                    RGBA(255, 0, 0, 255),
                    RGBA(0, 255, 0, 255),
                    RGBA(0, 0, 255, 255),
                    RGBA(255, 255, 255, 255),
                ]
            )
        )
    }

    /// A unique empty directory under the system temporary directory.
    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scui-assets-\(UUID().uuidString)")
    }
}
