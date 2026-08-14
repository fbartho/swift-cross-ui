import SwiftCrossUI
import SwiftCrossUIComponents
@testable import StaticHTMLBackend
import Testing

@MainActor
@Test func probeShape() {
    // Emit with view identity on, so data-scui shows the whole chain.
    func dump(_ l: String, _ v: some View) {
        var ctx = DocumentContext(title: "t")
        ctx.emitsViewIdentity = true
        let r = StaticHTMLRenderer.render(v, context: ctx)
        print("PROBE| === \(l) ===")
        guard let lo = r.html.range(of: "<div id=\"root\">"),
              let hi = r.html.range(of: "</body>") else { return }
        for line in String(r.html[lo.upperBound..<hi.lowerBound]).split(separator: "\n") {
            print("PROBE| \(line)")
        }
    }
    dump("BASE-GROUP", VStack { Group { Text("Only") } })
    dump("BASE-VSTACK1", VStack { VStack { Text("Only") } })
    dump("BASE-BUTTON", VStack { Button("Go") {} })
}
