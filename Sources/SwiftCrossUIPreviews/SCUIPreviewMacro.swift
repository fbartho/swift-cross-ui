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
/// Xcode runs a preview inside a host executable, chosen from the targets that
/// both depend on the previewed one and belong to the active scheme. When no
/// such executable exists it falls back to hosting the previewed module on its
/// own.
///
/// That choice decides which symbols the preview can reach:
///
/// | Previewing from | Previews render |
/// | --- | --- |
/// | An app target's scheme | Anything the app links, including package views |
/// | A package's own scheme | Views the previewed module itself builds |
///
/// Previewing a package's views from the package alone works as long as the
/// view and the preview are in one module. A body that reaches into another of
/// the package's modules reports "Missing Preview" instead: the fallback host
/// resolves only what the previewed module already links.
///
/// Both rows require a literal `#Preview`, which is what Xcode scans for. That
/// makes them inapplicable inside SwiftCrossUIPreviews itself, where the only
/// available spelling is ``SCUIPreview(_:body:)`` and nothing is displayed.
///
/// To preview across a package's modules, open it from an Xcode project whose
/// app target depends directly on the product containing the previewed file,
/// and make that app's scheme the active one. A transitive dependency isn't
/// enough for the app to be chosen as the host.
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
