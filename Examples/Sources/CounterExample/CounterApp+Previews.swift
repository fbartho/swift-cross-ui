import SwiftCrossUI
import SwiftCrossUIPreviews

// Renders CounterExample's own view in Xcode's preview canvas. Open
// Package.swift in Xcode, open this file, and show the canvas
// (option-command-return).
//
// This exists as usage documentation for previewing SwiftCrossUI components:
// write `#Preview` exactly as you would for a SwiftUI view. The closure's
// return type picks the SwiftCrossUI overload, so no conditional compilation
// is needed here -- the expansion is empty on platforms without a preview
// canvas, and this file still builds on Linux and Windows.

#Preview("Counter") {
    CounterPreviewWrapper()
}

/// Supplies a source of truth for ``CounterView``'s binding, since a preview
/// has nowhere else to hold state.
private struct CounterPreviewWrapper: View {
    @State private var count = 0

    var body: some View {
        CounterView(count: $count)
    }
}
