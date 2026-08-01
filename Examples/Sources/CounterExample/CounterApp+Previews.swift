import SwiftCrossUI
import SwiftCrossUIPreviews

#if canImport(SwiftUI) && canImport(AppKit) && !targetEnvironment(macCatalyst)
    import SwiftUI

    // CANVAS EXPERIMENT -- temporary, not the shipping shape.
    //
    // Xcode doesn't offer the canvas for a file whose previews come only from
    // `#SCUIPreview`, and force-opening it renders nothing, even though that
    // macro emits PreviewRegistry conformances indistinguishable from a
    // literal `#Preview`'s. These three previews narrow down what the canvas
    // actually keys on.
    //
    // 1. ANCHOR: SwiftUI's own `#Preview` on a SwiftUI view. Establishes that
    //    the canvas works at all in this file.
    // 2. OVERLOAD: bare `#Preview` on a SwiftCrossUI view, resolving to the
    //    overload declared in SwiftCrossUIPreviews. Carries the literal token,
    //    and registers the preview the same way `#SCUIPreview` does.
    // 3. MACRO: `#SCUIPreview`, below the gate.
    //
    // What each outcome means:
    //   1 + 2 + 3 -- rendering enumerates registrations; only the presence of
    //     a literal token in the file ever mattered.
    //   1 + 2     -- the literal token is required per call site, and the
    //     overload is the answer: ideal spelling, no gate needed.
    //   1 only    -- rendering is tied to SwiftUI's own macro specifically,
    //     and no custom macro can reach the canvas.
    @available(macOS 14.0, *)
    #Preview("1 ANCHOR (SwiftUI view)") {
        SwiftUI.Text("anchor")
            .font(.title)
    }

    @available(macOS 14.0, *)
    #Preview("2 OVERLOAD (SwiftCrossUI view)") {
        CounterPreviewWrapper()
    }
#endif

#SCUIPreview("3 MACRO (SwiftCrossUI view)") {
    CounterPreviewWrapper()
}

/// Supplies a source of truth for ``CounterView``'s binding, since a preview
/// has nowhere else to hold state.
private struct CounterPreviewWrapper: SwiftCrossUI.View {
    @SwiftCrossUI.State private var count = 0

    var body: some SwiftCrossUI.View {
        CounterView(count: $count)
    }
}
