// A minimal executable used to prove that SwiftCrossUI's core and DummyBackend
// actually run (not merely compile) under a wasm32-unknown-wasip1 runtime, and
// that the single-threaded WASI branch of `Publisher` delivers state updates.
//
// It deliberately avoids XCTest/swift-testing, both of which need more platform
// support than the wasm SDK currently offers. Failures are reported by exiting
// with a non-zero status so that a runtime harness can gate on it.

#if canImport(WASILibc)
    import WASILibc
#elseif canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(WinSDK)
    import WinSDK
#endif

import DummyBackend

@testable @_spi(Backends) import SwiftCrossUI

/// Mutable state shared with observation closures.
///
/// The closures are `@Sendable`, so capturing plain local `var`s would warn
/// about mutation after capture. On this runtime there is only ever one
/// thread, so a simple reference box is sufficient.
final class Box<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Tracks check results so the process can exit non-zero if anything failed.
final class Checker {
    private var failures: [String] = []
    private var passes = 0

    func expect(_ condition: Bool, _ description: String) {
        if condition {
            passes += 1
            print("ok   - \(description)")
        } else {
            failures.append(description)
            print("FAIL - \(description)")
        }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ description: String) {
        expect(actual == expected, "\(description) (got \(actual), expected \(expected))")
    }

    /// Prints a summary and returns the process exit code.
    func summarise() -> Int32 {
        print("")
        print("\(passes) passed, \(failures.count) failed")
        for failure in failures {
            print("  failed: \(failure)")
        }
        return failures.isEmpty ? 0 : 1
    }
}

@MainActor
func run() -> Int32 {
    let checker = Checker()

    print("== environment ==")
    print("SwiftCrossUI wasm smoke test starting")

    // MARK: Backend and view graph construction

    let backend = DummyBackend()
    let window = backend.createWindow(withDefaultSize: nil, id: "window")
    let environment = EnvironmentValues(backend: backend).with(\.window, window)

    print("")
    print("== layout ==")

    let view = VStack(spacing: 0) {
        Text("Hello")
        Text("wasm")
    }

    let node = ViewGraphNode(for: view, backend: backend, environment: environment)
    let layout = node.computeLayout(
        proposedSize: ProposedViewSize(200, 100),
        environment: environment
    )
    _ = node.commit()

    print("root layout size: \(layout.size.vector.x) x \(layout.size.vector.y)")
    checker.expect(layout.size.vector.x > 0, "root layout has positive width")
    checker.expect(layout.size.vector.y > 0, "root layout has positive height")

    let children = node.widget.getChildren()
    print("root widget child count: \(children.count)")
    checker.expectEqual(children.count, 2, "VStack committed two children")

    for (index, child) in children.enumerated() {
        print("  child \(index) size: \(child.size.x) x \(child.size.y)")
    }

    // The two text children stack vertically, so the container must be at
    // least as tall as their combined height.
    if children.count == 2 {
        let combinedHeight = children[0].size.y + children[1].size.y
        checker.expect(
            layout.size.vector.y >= combinedHeight,
            "container height accommodates both stacked children"
        )
    }

    // MARK: Publisher delivery

    print("")
    print("== publisher: basic observation ==")

    let publisher = Publisher()
    let directObservations = Box(0)
    let directCancellable = publisher.observe {
        directObservations.value += 1
    }

    publisher.send()
    checker.expectEqual(directObservations.value, 1, "direct observation fires once per send")

    publisher.send()
    checker.expectEqual(directObservations.value, 2, "direct observation fires again")

    directCancellable.cancel()
    publisher.send()
    checker.expectEqual(directObservations.value, 2, "cancelled observation stops firing")

    // MARK: ObservableObject integration

    print("")
    print("== publisher: observable object ==")

    class MyState: SwiftCrossUI.ObservableObject {
        @SwiftCrossUI.Published
        var count = 0
    }

    let state = MyState()
    let stateObservations = Box(0)
    let stateCancellable = state.didChange.observe {
        stateObservations.value += 1
    }

    state.count += 1
    checker.expectEqual(stateObservations.value, 1, "@Published mutation triggers observation")
    stateCancellable.cancel()

    // MARK: observeAsUIUpdater on the WASI path
    //
    // A single-threaded runtime has no second thread to signal a semaphore or
    // drain a Dispatch queue, so any scheme that defers delivery risks
    // dropping every update after the first. The property that matters most
    // here is therefore that the FINAL update in a rapid burst is delivered.

    print("")
    print("== publisher: observeAsUIUpdater ==")

    let uiPublisher = Publisher()
    let updateCount = Box(0)
    let lastSeenGeneration = Box(-1)
    let generation = Box(0)

    let uiCancellable = uiPublisher.observeAsUIUpdater(backend: backend) {
        updateCount.value += 1
        lastSeenGeneration.value = generation.value
    }

    // A single update must be delivered synchronously on this runtime: there
    // is no other thread that could run it later, so anything not delivered
    // by the time `send()` returns is lost.
    generation.value = 0
    uiPublisher.send()
    checker.expectEqual(updateCount.value, 1, "first UI update is delivered")
    checker.expectEqual(lastSeenGeneration.value, 0, "first UI update sees current generation")

    // A rapid burst — the case where a deferred-delivery scheme drops
    // updates on this runtime.
    let burstSize = 50
    for index in 1...burstSize {
        generation.value = index
        uiPublisher.send()
    }

    print("updates delivered after burst of \(burstSize): \(updateCount.value)")
    print("last generation observed: \(lastSeenGeneration.value)")

    checker.expect(
        updateCount.value > 1,
        "UI updates continue to be delivered after the first one"
    )
    checker.expectEqual(
        lastSeenGeneration.value,
        burstSize,
        "final update of a rapid burst is never dropped"
    )

    uiCancellable.cancel()
    let countAfterCancel = updateCount.value
    uiPublisher.send()
    checker.expectEqual(
        updateCount.value,
        countAfterCancel,
        "cancelled UI updater stops receiving updates"
    )

    // MARK: State-driven view update
    //
    // Ties the two halves together: a state mutation routed through
    // observeAsUIUpdater should be able to drive a real layout recomputation
    // without trapping or hanging.

    print("")
    print("== state-driven relayout ==")

    let reactiveState = MyState()
    let relayoutCount = Box(0)
    let relayoutCancellable = reactiveState.didChange.observeAsUIUpdater(backend: backend) {
        let node = ViewGraphNode(
            for: Text("count: \(reactiveState.count)"),
            backend: backend,
            environment: environment
        )
        _ = node.computeLayout(
            proposedSize: ProposedViewSize(200, 100),
            environment: environment
        )
        _ = node.commit()
        relayoutCount.value += 1
    }

    for _ in 0..<10 {
        reactiveState.count += 1
    }

    print("relayouts performed: \(relayoutCount.value)")
    checker.expect(relayoutCount.value > 0, "state mutation drives a layout pass")
    checker.expectEqual(
        reactiveState.count,
        10,
        "all state mutations applied"
    )
    relayoutCancellable.cancel()

    print("")
    print("== done ==")
    return checker.summarise()
}

exit(MainActor.assumeIsolated { run() })
