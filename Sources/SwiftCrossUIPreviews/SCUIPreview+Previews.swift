import SwiftCrossUI

// Renders SwiftCrossUI views in Xcode's preview canvas. Open Package.swift in
// Xcode, open this file, and show the canvas (option-command-return).
//
// These render `SCUIPreviewGallery`'s views, which the snapshot tool renders
// too, so the canvas and the recorded snapshots stay in agreement.
//
// Note the lack of conditional compilation: `#SCUIPreview` expands to nothing
// on platforms without a preview canvas, so this file builds everywhere.

#SCUIPreview("Counter") {
    CounterSample()
}

#SCUIPreview("Text") {
    SwiftCrossUI.Text("Hello, world!")
        .font(.title)
}
