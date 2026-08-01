import DefaultBackend
import SwiftCrossUI

#if canImport(SwiftBundlerRuntime)
    import SwiftBundlerRuntime
#endif

@main
@HotReloadable
struct CounterApp: App {
    @State var count = 0

    var body: some Scene {
        WindowGroup("CounterExample: \(count)") {
            #hotReloadable {
                CounterView(count: $count)
            }
        }
        .defaultSize(width: 400, height: 200)
    }
}

/// The counter's contents, factored out of ``CounterApp`` so that it can be
/// rendered both by the app and by the `#Preview` in
/// `CounterApp+Previews.swift`.
struct CounterView: View {
    @Binding var count: Int

    var body: some View {
        HStack(spacing: 20) {
            Button("-") {
                count -= 1
            }
            Text("Count: \(count)")
            Button("+") {
                count += 1
            }
        }
        .padding()
    }
}
