import SwiftCrossUI

// Previews of `SCUIPreviewGallery`'s views -- the same views the snapshot tool
// renders, so the two stay in agreement.
//
// These use `#SCUIPreview` rather than `#Preview` because the overload can't
// be used inside the module that declares it, and Xcode's canvas doesn't
// display `#SCUIPreview` previews. They therefore exist as registrations
// rather than as something you can look at; to see these views in the canvas,
// preview them from a module that imports SwiftCrossUIPreviews.

#SCUIPreview("Counter") {
    CounterSample()
}

#SCUIPreview("Text") {
    SwiftCrossUI.Text("Hello, world!")
        .font(.title)
}
