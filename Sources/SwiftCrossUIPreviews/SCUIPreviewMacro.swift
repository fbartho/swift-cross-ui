import SwiftCrossUI

/// Registers a SwiftCrossUI view as a preview, under a name of our own.
///
/// Prefer ``Preview(_:body:)``, which is spelled the same way as SwiftUI's
/// macro. **Xcode's canvas does not display previews written with
/// `#SCUIPreview`.** The canvas scans source for the literal `#Preview` token
/// and looks up a registration whose mangled name encodes that spelling, so a
/// preview registered under any other name compiles correctly, carries the
/// same metadata as any other, and is never shown.
///
/// What it's still for: previewing from inside SwiftCrossUIPreviews itself,
/// where ``Preview(_:body:)`` can't be used. A same-module macro declaration
/// outranks an imported one, so within this module `#Preview` always resolves
/// to our overload, and previews of genuine SwiftUI views stop compiling.
///
/// ```swift
/// #SCUIPreview("Greeting") {
///     VStack {
///         Text("Hello, world!")
///         Button("Press me") {}
///     }
/// }
/// ```
///
/// Like ``Preview(_:body:)``, this needs no conditional compilation: the
/// expansion is empty on platforms without a preview canvas, so the same file
/// builds unchanged on Linux and Windows.
///
/// - Parameters:
///   - name: A display name for the preview. Xcode won't show it, for the
///     reason above.
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
