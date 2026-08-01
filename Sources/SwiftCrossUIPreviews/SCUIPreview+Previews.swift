import SwiftCrossUI

// Renders SwiftCrossUI views in Xcode's preview canvas. Open Package.swift in
// Xcode, open this file, and show the canvas (option-command-return).
//
// These render `SCUIPreviewGallery`'s views, which the snapshot tool renders
// too, so the canvas and the recorded snapshots stay in agreement.

#SCUIPreview("Counter") {
    CounterSample()
}

#SCUIPreview("Text") {
    SwiftCrossUI.Text("Hello, world!")
        .font(.title)
}
