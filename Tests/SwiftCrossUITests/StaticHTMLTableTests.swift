import Testing

import Foundation
import StaticHTMLBackend
@_spi(Backends) import SwiftCrossUI

@Suite("Testing table and split-view emission for the static HTML backend")
struct StaticHTMLTableTests {
    /// A row of the table the tests render.
    private struct Person {
        var name: String
        var role: String
    }

    private static let people = [
        Person(name: "Ada", role: "Engineer"),
        Person(name: "Grace", role: "Admiral"),
    ]

    @MainActor
    @Test("A Table emits real table markup, not a grid of divs")
    func tableEmitsTableElement() {
        let html = Self.renderTable()

        #expect(html.contains("<table"))
        #expect(html.contains("<thead>"))
        #expect(html.contains("<tbody>"))
        #expect(html.contains("</table>"))
    }

    @MainActor
    @Test("Column labels become header cells scoped to their column")
    func columnLabelsBecomeScopedHeaders() {
        // scope="col" is what declares the header/data relationship to a
        // screen reader; a <th> inside <thead> is only conventionally a column
        // header without it.
        let html = Self.renderTable()

        #expect(html.contains("<th scope=\"col\""))
        #expect(html.contains(">Name</th>"))
        #expect(html.contains(">Role</th>"))
    }

    @MainActor
    @Test("Cells are grouped into one row element per row of data")
    func cellsGroupIntoRows() {
        // Cells reach the backend as one flat array in row-major order, so
        // the column count is the only thing that recovers the row boundaries
        // — an off-by-one here would emit every cell in a single row.
        let html = Self.renderTable()

        #expect(Self.count(of: "<tr>", in: html) == 3)
        #expect(Self.count(of: "<td", in: html) == 4)
    }

    @MainActor
    @Test("Cell content survives into the table body")
    func cellContentReachesTheDocument() {
        let html = Self.renderTable()

        #expect(html.contains("Ada"))
        #expect(html.contains("Grace"))
        #expect(html.contains("Admiral"))
    }

    @MainActor
    @Test("A table is wrapped in a focusable horizontal scroll box")
    func tableIsWrappedInAScrollBox() {
        // A table's column count is fixed by its data, so it can't reflow the
        // way the rest of the document does. The wrapper is what keeps a wide
        // table from giving the whole page a horizontal scrollbar, and
        // tabindex is what lets a keyboard reach the scrollable region.
        let html = Self.renderTable()

        #expect(html.contains("tabindex=\"0\""))
        #expect(Self.rule(containing: "overflow-x", in: html)?.contains("auto") == true)
    }

    @MainActor
    @Test("The scroll box and its ancestors are capped so overflow-x can engage")
    func scrollBoxAncestorsAreCapped() {
        // overflow-x only scrolls a box narrower than its content, and every
        // ancestor between the scroll box and the viewport is shrink-to-fit
        // here — so without these caps a wide table grew the whole chain to
        // max-content and overflowed the page instead of scrolling (measured
        // in Chrome: a 1021px table at a 480px viewport took the document's
        // scroll width to 775px, with the wrapper never scrolling).
        let html = Self.renderTable()

        #expect(html.contains("data-scui-tablescroll"))
        let rule = Self.rule(containing: "div:has([data-scui-tablescroll])", in: html)
        #expect(rule != nil)
        // Zero specificity, so an interned class still outranks it.
        #expect(rule?.contains(":where(") == true)
    }

    @MainActor
    @Test("A document with no table carries none of the table stylesheet")
    func tableStylesheetIsConditional() {
        let html = Self.renderSplitView()

        #expect(!html.contains("data-scui-tablescroll"))
    }

    @MainActor
    @Test("No row carries a baked-in height from the build host")
    func rowHeightsAreNotBaked() {
        // The core hands the backend a measured height per row, but those come
        // from the build host's text estimate. Emitting them would clip or
        // stretch rows once a real font engine re-wraps the same text.
        let html = Self.renderTable()

        #expect(!html.contains("<tr style"))
        for line in html.split(separator: "\n") where line.contains("<tr") {
            #expect(!line.contains("height"))
        }
    }

    @MainActor
    @Test("A NavigationSplitView renders both panes rather than trapping")
    func splitViewRendersBothPanes() {
        let html = Self.renderSplitView()

        #expect(html.contains("Sidebar item"))
        #expect(html.contains("Detail body"))
    }

    @MainActor
    @Test("The two panes emit as navigation and main landmarks")
    func panesCarryLandmarkElements() {
        // The pane containers the core builds are plain containers with no way
        // to say which is the sidebar. The landmark pair is the accessibility
        // win this tier is positioned to deliver, so the backend supplies it.
        let html = Self.renderSplitView()

        #expect(html.contains("<nav"))
        #expect(html.contains("</nav>"))
        #expect(html.contains("<main"))
        #expect(html.contains("</main>"))
    }

    @MainActor
    @Test("The split is a wrapping flex row, so it collapses instead of overflowing")
    func splitViewWrapsRatherThanOverflowing() {
        // flex-wrap is what makes the row degrade to a stacked layout once the
        // detail pane's minimum no longer fits beside the sidebar — reached
        // through flow rules rather than a media query, so it responds to the
        // space actually available.
        let html = Self.renderSplitView()
        let row = Self.rule(containing: "flex-wrap", in: html)

        #expect(row?.contains("wrap") == true)
        #expect(row?.contains("flex-direction:row") == true)
    }

    @MainActor
    @Test("The sidebar starts at its reported width and the detail pane takes the rest")
    func panesCarryTheirFlexSizing() {
        let html = Self.renderSplitView()

        #expect(Self.rule(containing: "flex-basis:260px", in: html) != nil)
        #expect(Self.rule(containing: "min-width:320px", in: html) != nil)
    }

    @MainActor
    @Test("Sidebar width bounds reach the emitted CSS")
    func sidebarBoundsReachTheMarkup() {
        // setSidebarWidthBounds is the one split-view protocol method with a
        // real static meaning: the bounds are a layout constraint, not an
        // interaction, so min/max-width carry them honestly.
        let html = Self.renderSplitView()
        let sidebar = Self.rule(containing: "flex-basis:260px", in: html)

        #expect(sidebar?.contains("min-width") == true)
        #expect(sidebar?.contains("max-width") == true)
    }

    @MainActor
    @Test("Neither pane pins a build-host width that would block reflow")
    func panesDoNotPinCommittedWidths() {
        // The panes are positioned by the core against a fixed sidebar width;
        // carrying that through as a literal width would defeat the wrap.
        let html = Self.renderSplitView()

        for line in html.split(separator: "\n")
            where line.contains("<nav") || line.contains("<main")
        {
            #expect(!line.contains("position:absolute"))
        }
    }

    /// Renders a two-column table of ``people``.
    @MainActor
    private static func renderTable() -> String {
        StaticHTMLRenderer.render(
            Table(people) {
                TableColumn<Person, Text>("Name", value: \.name)
                TableColumn<Person, Text>("Role", value: \.role)
            },
            context: "Tables",
            size: SIMD2(600, 400)
        ).html
    }

    /// Renders a two-pane split view.
    @MainActor
    private static func renderSplitView() -> String {
        StaticHTMLRenderer.render(
            NavigationSplitView {
                Text("Sidebar item")
            } detail: {
                Text("Detail body")
            },
            context: "SplitView",
            size: SIMD2(900, 600)
        ).html
    }

    /// The first stylesheet rule containing a marker.
    private static func rule(containing marker: String, in html: String) -> String? {
        html.split(separator: "\n").first { $0.contains(marker) }.map(String.init)
    }

    /// How many times a substring occurs in a document.
    private static func count(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
