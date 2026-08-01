#if canImport(SwiftUI) && canImport(AppKit) && !targetEnvironment(macCatalyst)
    import SwiftUI

    import SwiftCrossUI

    // Renders SwiftCrossUI views in Xcode's preview canvas. Open Package.swift
    // in Xcode, open this file, and show the canvas (option-command-return).
    //
    // These render `SCUIPreviewGallery`'s views, which the snapshot tool renders
    // too, so the canvas and the recorded snapshots stay in agreement.

    @available(macOS 14.0, *)
    #Preview("Counter") {
        SCUIPreview {
            CounterSample()
        }
    }

    @available(macOS 14.0, *)
    #Preview("Text") {
        SCUIPreview {
            SwiftCrossUI.Text("Hello, world!")
                .font(.title)
        }
    }
#endif
