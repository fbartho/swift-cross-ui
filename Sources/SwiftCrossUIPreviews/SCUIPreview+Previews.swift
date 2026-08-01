import SwiftCrossUI

#if canImport(SwiftUI) && canImport(AppKit) && !targetEnvironment(macCatalyst)
    import SwiftUI

    // HYBRID EXPERIMENT -- temporary, not the shipping shape.
    //
    // A literal `#Preview` written in source, sitting alongside the two
    // `#SCUIPreview` blocks below. The question is whether the canvas, once
    // activated by seeing this literal token in the file, then renders every
    // registered preview, or only the ones it found by scanning source.
    //
    // Canvas contents if rendering enumerates registrations:
    //     ANCHOR, Counter, Text -- three previews.
    // Canvas contents if rendering is also token-keyed:
    //     ANCHOR only.
    @available(macOS 14.0, *)
    #Preview("ANCHOR (literal #Preview)") {
        SCUIPreview {
            SwiftCrossUI.Text("anchor")
                .font(.title)
        }
    }
#endif

#SCUIPreview("Counter") {
    CounterSample()
}

#SCUIPreview("Text") {
    SwiftCrossUI.Text("Hello, world!")
        .font(.title)
}
