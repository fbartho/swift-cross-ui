import SwiftCrossUI

#if canImport(SwiftUI) && canImport(AppKit) && !targetEnvironment(macCatalyst)
    import SwiftUI

    import SwiftCrossUIPreviews

    // CANVAS EXPERIMENT -- temporary scaffolding, deleted before the PR.
    //
    // Xcode recognises previews 1 and 2 but not 3, which says the literal
    // `#Preview` token is what makes a preview visible, per call site: the
    // overload carries it, `#SCUIPreview` doesn't. This target exists to
    // confirm that previews 1 and 2 also *render*, which the earlier probe
    // couldn't show -- it lived in an SPM executable, and Xcode refuses to
    // render previews there without ENABLE_DEBUG_DYLIB.
    //
    // A library target sidesteps that. It also has to be a separate target
    // from SwiftCrossUIPreviews: inside the declaring module a same-module
    // macro outranks the imported SwiftUI one, so `#Preview` would resolve to
    // the overload even for preview 1 and fail to compile.
    //
    // 1. ANCHOR: SwiftUI's own `#Preview` on a SwiftUI view.
    // 2. OVERLOAD: bare `#Preview` on a SwiftCrossUI view.
    // 3. MACRO: `#SCUIPreview` -- expected to stay invisible.

    @available(macOS 14.0, *)
    #Preview("1 ANCHOR (SwiftUI view)") {
        SwiftUI.Text("anchor")
            .font(.title)
    }

    @available(macOS 14.0, *)
    #Preview("2 OVERLOAD (SwiftCrossUI view)") {
        CounterProbe()
    }

    #SCUIPreview("3 MACRO (SwiftCrossUI view)") {
        CounterProbe()
    }

    /// A SwiftCrossUI view with state, so that a rendered preview is visibly
    /// live rather than a static string.
    private struct CounterProbe: SwiftCrossUI.View {
        @SwiftCrossUI.State private var count = 0

        var body: some SwiftCrossUI.View {
            VStack {
                SwiftCrossUI.Text("count: \(count)")
                    .font(.title)
                SwiftCrossUI.Button("Increment") {
                    count += 1
                }
            }
        }
    }
#endif
