import SwiftCrossUI

/// Registers a SwiftCrossUI view as a preview, under a name Xcode's canvas
/// doesn't recognise.
///
/// Prefer ``Preview(_:body:)``, which is spelled the same way as SwiftUI's
/// macro. **Xcode's canvas does not display previews written with
/// `#SCUIPreview`.** The canvas scans source for the literal `#Preview` token
/// and looks up a registration whose mangled name encodes that spelling, so a
/// preview registered under any other name compiles correctly, carries the same
/// metadata as any other, and is never shown.
///
/// It remains useful for previewing from inside SwiftCrossUIPreviews itself,
/// where ``Preview(_:body:)`` can't be used.
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

/// Previews a SwiftCrossUI view in Xcode's canvas, spelled the same way as
/// SwiftUI's `#Preview`.
///
/// This overloads SwiftUI's macro rather than replacing it. The closure's return
/// type selects between them, so one file can preview both kinds of view with
/// the same spelling:
///
/// ```swift
/// #Preview("Native") { SwiftUI.Text("hi") }        // SwiftUI's
/// #Preview("Cross-platform") { CounterView() }     // this one
/// ```
///
/// Unlike wrapping a view in ``SCUIPreview`` by hand, this needs no conditional
/// compilation and no availability annotation. The expansion is empty on
/// platforms that have no preview canvas, so a file using it builds unchanged on
/// Linux and Windows, and the availability the registration needs is part of the
/// expansion.
///
/// ## Where previews appear
///
/// Xcode renders previews by loading the built code into a separate agent
/// process, which requires the `ENABLE_DEBUG_DYLIB` build setting. Where a
/// preview is written decides whether that setting is available:
///
/// | Context | Previews render |
/// | --- | --- |
/// | Xcode project, app target | Yes, by default |
/// | Xcode project, command-line tool target | Yes, with `ENABLE_DEBUG_DYLIB` set to `YES` |
/// | Swift package | Only for views the previewed file's own module builds |
///
/// A Swift package target has no way to set `ENABLE_DEBUG_DYLIB`, so the agent
/// can only resolve what it already has loaded. Previews of views defined in the
/// same module as the preview itself render; previews whose body reaches into
/// another module of the package report "Missing Preview" instead. To preview
/// components of a package, open the package from an Xcode project that depends
/// on it.
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
