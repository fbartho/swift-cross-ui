#if canImport(SwiftUI) && canImport(AppKit) && !targetEnvironment(macCatalyst)
    import SwiftUI

    import SwiftCrossUI
    import SwiftCrossUIPreviews

    // Renders CounterExample's own view in Xcode's preview canvas. Open
    // Package.swift in Xcode, open this file, and show the canvas
    // (option-command-return).
    //
    // This exists as usage documentation for previewing SwiftCrossUI
    // components with SCUIPreview: wrap the view you want to preview in an
    // `SCUIPreview { ... }`, gated behind the same conditional compilation
    // and availability checks used here.

    @available(macOS 14.0, *)
    #Preview("Counter") {
        SCUIPreview {
            CounterPreviewWrapper()
        }
    }

    /// Supplies a source of truth for ``CounterView``'s binding, since a
    /// `#Preview` has nowhere else to hold state.
    ///
    /// - Note: Explicitly qualified as `SwiftCrossUI.View`/`SwiftCrossUI.State`
    ///   because this file also imports SwiftUI for `#Preview`, and both
    ///   frameworks declare types with these names.
    private struct CounterPreviewWrapper: SwiftCrossUI.View {
        @SwiftCrossUI.State private var count = 0

        var body: some SwiftCrossUI.View {
            CounterView(count: $count)
        }
    }
#endif
