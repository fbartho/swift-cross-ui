import SwiftCrossUI

/// Registers a SwiftCrossUI view with Xcode's preview canvas.
///
/// ```swift
/// import SwiftCrossUI
/// import SwiftCrossUIPreviews
///
/// #SCUIPreview("Greeting") {
///     VStack {
///         Text("Hello, world!")
///         Button("Press me") {}
///     }
/// }
/// ```
///
/// The macro is portable, and is the reason previews don't need a
/// `#if canImport(SwiftUI)` guard around them: it expands to a preview
/// registration on platforms that have a canvas, and to nothing at all
/// elsewhere, so the same file builds unchanged on Linux and Windows.
///
/// This is spelled `#SCUIPreview` rather than overloading SwiftUI's
/// `#Preview`. An overload is resolvable — the closure's return type picks
/// between the two — but declaring one makes `#Preview` ambiguous for
/// *SwiftUI* views in any file that can see this module, which would break
/// previews of ordinary SwiftUI views. A distinct name keeps both spellings
/// usable in the same file.
///
/// - Parameters:
///   - name: A display name for the preview, shown in Xcode's canvas. Defaults
///     to no name, in which case Xcode labels the preview by source location.
///   - body: A closure returning the view to preview. It is evaluated once when
///     the preview is created.
@freestanding(declaration)
public macro SCUIPreview<Content: SwiftCrossUI.View>(
    _ name: String? = nil,
    @SwiftCrossUI.ViewBuilder body: @escaping () -> Content
) = #externalMacro(module: "SwiftCrossUIMacrosPlugin", type: "SCUIPreviewMacro")
