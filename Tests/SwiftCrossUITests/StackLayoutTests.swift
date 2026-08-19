import Testing

import DummyBackend
@testable @_spi(Backends) import SwiftCrossUI

@Suite("Testing for stack layouts")
struct StackLayoutTests {
    let backend: DummyBackend
    let window: DummyBackend.Window
    let environment: EnvironmentValues

    @MainActor
    init() {
        backend = DummyBackend()
        window = backend.createWindow(withDefaultSize: nil, id: "window")
        environment = EnvironmentValues(backend: backend).with(\.window, window)
    }

    @MainActor
    @Test("Empty ScrollView should still be greedy in stack (#328)")
    func emptyScrollViewInStack() {
        let view = VStack {
            Text("Dummy")
            ScrollView {}
        }

        let height = 200.0
        let result = computeLayout(of: view, proposedSize: ProposedViewSize(100, height))

        #expect(result.size.height == height)
    }

    @MainActor
    @Test("Fixed size stack redistributes space (#453)")
    func fixedSizeStackSpaceRedistribution() {
        let view = VStack(spacing: 0) {
            Text("Dummy")
            Color.blue
            Text("Dummy")
        }.fixedSize()

        let node = committedNode(for: view, proposedSize: ProposedViewSize(200, 200))

        let fixedSizeWidget = node.widget.getChildren()[0]
        let children = fixedSizeWidget.getChildren()
        let text1 = children[0]
        let color = children[1]
        let text2 = children[2]

        // Ensure #453 resolved
        #expect(text1.size.x == color.size.x)

        // Sanity checks
        #expect(text1.size == text2.size)
    }

    @MainActor
    @Test("Spacer layout priority")
    func spacerLayoutPriority() {
        let strings = ["AA", "AAAA"]
        let view = HStack(spacing: 0) {
            Text(strings[0])
            Spacer(minLength: 0)
            Text(strings[1])
        }

        let lineHeight = environment.resolvedFont.lineHeight

        let textResults = strings.map(Text.init(_:)).map { computeLayout(of: $0) }
        let minimumWidthWithoutWrapping = textResults.map(\.size.vector.x).reduce(0, +)
        let proposedSize = ProposedViewSize(
            Double(minimumWidthWithoutWrapping),
            lineHeight * 2
        )
        let result = computeLayout(of: view, proposedSize: proposedSize)

        // No wrapping, and perfect fit
        #expect(result.size.height == environment.resolvedFont.lineHeight)
        #expect(result.size.vector.x == minimumWidthWithoutWrapping)
    }

    @MainActor
    @Test("A backend that ignores the flexibility hook lays stacks out unchanged")
    func flexibilityHookDegradesToNoOp() {
        // describeChildFlexibility is observability only: DummyBackend takes
        // the protocol's no-op default, so committing a stack whose children
        // carry diverging priorities must produce the same geometry as one
        // whose children carry none.
        let prioritized = VStack(spacing: 0) {
            Text("Dummy")
            Text("Dummy").layoutPriority(1)
        }
        let plain = VStack(spacing: 0) {
            Text("Dummy")
            Text("Dummy")
        }

        let proposedSize = ProposedViewSize(200, 400)
        let prioritizedResult = computeLayout(of: prioritized, proposedSize: proposedSize)
        let plainResult = computeLayout(of: plain, proposedSize: proposedSize)

        #expect(prioritizedResult.size == plainResult.size)

        // Reaching the end is the rest of the assertion: the hook's call
        // site indexes per-child arrays, and ZStack's cache carries none, so
        // a shape mismatch would trap during commit rather than return a
        // wrong size.
        _ = committedNode(for: prioritized, proposedSize: proposedSize)
        _ = committedNode(for: ZStack { Text("Dummy") }, proposedSize: proposedSize)
    }

    // MARK: Helpers

    @MainActor
    func computeLayout<V: View>(
        of view: V,
        proposedSize: ProposedViewSize = .unspecified
    ) -> ViewLayoutResult {
        let node = ViewGraphNode(for: view, backend: backend, environment: environment)
        return node.computeLayout(
            proposedSize: proposedSize,
            environment: environment
        )
    }

    @MainActor
    func committedNode<V: View>(
        for view: V,
        proposedSize: ProposedViewSize = .unspecified
    ) -> ViewGraphNode<V, DummyBackend> {
        let node = ViewGraphNode(for: view, backend: backend, environment: environment)
        _ = node.computeLayout(proposedSize: proposedSize, environment: environment)
        _ = node.commit()
        return node
    }
}
