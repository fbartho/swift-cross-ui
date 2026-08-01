import SwiftCrossUI
import SwiftCrossUIPreviews

// Renders CounterExample's own view in Xcode's preview canvas. Open
// Package.swift in Xcode, open this file, and show the canvas
// (option-command-return).
//
// This exists as usage documentation for previewing SwiftCrossUI components:
// write `#SCUIPreview { ... }` around the view you want to see. No conditional
// compilation is needed -- the macro expands to nothing on platforms without a
// preview canvas, so this file still builds on Linux and Windows.

#SCUIPreview("Counter") {
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
