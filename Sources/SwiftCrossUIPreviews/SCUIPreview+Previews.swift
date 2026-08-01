import SwiftCrossUI

// Previews of `SCUIPreviewGallery`'s views -- the same views the snapshot tool
// renders, so the two stay in agreement.
//
// These use `#SCUIPreview` because neither spelling of `#Preview` is available
// here: a same-module macro declaration outranks an imported one, so `#Preview`
// resolves to ``Preview(_:body:)`` whatever the body's type, and a macro name
// can't be module-qualified to reach SwiftUI's. Xcode doesn't display
// `#SCUIPreview` previews, so these register the gallery's views without being
// viewable from this module; preview them from a module that imports
// SwiftCrossUIPreviews.

#SCUIPreview("Counter") {
    CounterSample()
}

#SCUIPreview("Text") {
    SwiftCrossUI.Text("Hello, world!")
        .font(.title)
}
