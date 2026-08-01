#if canImport(SwiftUI) && canImport(AppKit) && !targetEnvironment(macCatalyst)
    import SwiftUI

    import SwiftCrossUI

    /// A sample view demonstrating ``SCUIPreview``.
    ///
    /// Exercises text styling, a button, and stack layout so that the preview
    /// shows a non-trivial layout rather than a single label.
    private struct SampleView: SwiftCrossUI.View {
        @SwiftCrossUI.State var count = 0

        var body: some SwiftCrossUI.View {
            SwiftCrossUI.VStack {
                SwiftCrossUI.Text("SwiftCrossUI in Xcode")
                    .font(.title)
                SwiftCrossUI.Text("Count: \(count)")
                SwiftCrossUI.Button("Increment") {
                    count += 1
                }
            }
            .padding()
        }
    }

    @available(macOS 14.0, *)
    #Preview("SCUIPreview") {
        SCUIPreview {
            SampleView()
        }
    }
#endif
