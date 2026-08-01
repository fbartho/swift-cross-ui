import SwiftCrossUI

#if canImport(SwiftUI) && canImport(AppKit) && !targetEnvironment(macCatalyst)
    import SwiftUI

    import SwiftCrossUIPreviews

    // CANVAS EXPERIMENT -- temporary scaffolding, deleted before the PR.
    //
    // This target exists to confirm that the overload's previews *render* in
    // Xcode's canvas, which the earlier probe couldn't show -- it lived in an
    // SPM executable, and Xcode refuses to render previews there without
    // ENABLE_DEBUG_DYLIB.
    //
    // A library target sidesteps that. It also has to be a separate target
    // from SwiftCrossUIPreviews: inside the declaring module a same-module
    // macro outranks the imported SwiftUI one, so `#Preview` would resolve to
    // the overload even for preview 1 and fail to compile.
    //
    // 1. ANCHOR: SwiftUI's own `#Preview` on a SwiftUI view.
    // 2. OVERLOAD: bare `#Preview` on a SwiftCrossUI view.
    // 3. MACRO: `#SCUIPreview` -- expected to stay invisible.
    //
    // Previews 1 and 2 now mangle to identical registry identities, differing
    // only in source position and expansion ordinal, verified with `nm` and
    // `swift-demangle` on this file's object. The expansion frame encodes the
    // macro's base name, the consuming module, and the call site -- not the
    // module that declared the macro -- so the overload's registrations are
    // indistinguishable from SwiftUI's to the canvas's lookup.
    //
    // A first canvas run still reported "Missing Preview" for preview 2, but
    // not because the identity failed to match. Xcode's log narrates three
    // `XOJIT Link Error`s immediately before the preview agent disconnects,
    // and the launch thunk has exactly three unresolved SwiftCrossUIPreviews
    // symbols: SCUIPreview's nominal type descriptor, its initializer, and
    // its SwiftUI.View conformance descriptor. Preview 1 needs nothing
    // outside SwiftUI and DeveloperToolsSupport, so it links and renders;
    // preview 2 needs symbols from a package target that builds as a static
    // object, which the agent's JIT linker can't resolve.
    //
    // Building the products as dynamic libraries exports those three symbols,
    // so set SCUI_LIBRARY_TYPE=dynamic in the scheme before drawing any
    // conclusion about the registration itself.
    //
    // TEST PROCEDURE
    //
    // 1. Open Package.swift in Xcode (File > Open, select the repo root).
    // 2. Choose the `SCUIPreviewProbe` scheme, destination `My Mac`.
    // 3. Edit the scheme: Run > Arguments > Environment Variables, and add
    //    `SCUI_LIBRARY_TYPE` = `dynamic`. Without it the package builds
    //    static objects and preview 2 can't link, however correct its
    //    registration is.
    // 4. Open this file (Sources/SCUIPreviewProbe/CanvasProbe.swift).
    // 5. Show the canvas with option-command-return, and resume it if it
    //    isn't already running.
    //
    // Expected result, per numbered preview:
    //
    // - "1 ANCHOR (SwiftUI view)": a tab that renders the text "anchor".
    //   This is SwiftUI's own macro and is the control -- if it fails, the
    //   canvas itself isn't working and the other two prove nothing.
    // - "2 OVERLOAD (SwiftCrossUI view)": a tab that renders the SwiftCrossUI
    //   counter, with a working Increment button. "Missing Preview" here,
    //   with the dynamic build in place, would mean the linker theory is
    //   wrong and the canvas rejects the registration for some other reason.
    // - "3 MACRO (SwiftCrossUI view)": no tab at all. `#SCUIPreview` still
    //   lacks the literal `#Preview` token that the canvas scans for, so
    //   direct emission doesn't change its visibility -- it registers
    //   correctly and stays unshown.

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
