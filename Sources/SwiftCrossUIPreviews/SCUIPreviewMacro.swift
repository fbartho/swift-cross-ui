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

/// Registers a SwiftCrossUI view with Xcode's preview canvas, spelled the same
/// way as SwiftUI's `#Preview`.
///
/// This overloads SwiftUI's macro rather than replacing it. The closure's
/// return type selects between them, so a file can preview SwiftUI views and
/// SwiftCrossUI views with the same spelling:
///
/// ```swift
/// #Preview("Native") { SwiftUI.Text("hi") }        // SwiftUI's
/// #Preview("Cross-platform") { CounterView() }     // this one
/// ```
///
/// Like ``SCUIPreview(_:body:)`` it needs no conditional compilation: the
/// expansion is empty on platforms without a preview canvas.
///
/// - Note: This overload can't be used inside SwiftCrossUIPreviews itself. A
///   same-module declaration outranks the imported SwiftUI one, so within this
///   module `#Preview` always resolves here, and previews of genuine SwiftUI
///   views stop compiling. Consumers are unaffected, since for them neither
///   declaration is same-module and the closure's type decides.
///
/// - Parameters:
///   - name: A display name for the preview, shown in Xcode's canvas.
///   - body: A closure returning the view to preview.
@freestanding(declaration)
public macro Preview<Content: SwiftCrossUI.View>(
    _ name: String? = nil,
    @SwiftCrossUI.ViewBuilder body: @escaping () -> Content
) = #externalMacro(module: "SwiftCrossUIMacrosPlugin", type: "SCUIPreviewMacro")
