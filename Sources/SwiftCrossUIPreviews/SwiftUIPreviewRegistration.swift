#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
    import SwiftUI

    // SwiftUI's preview registration expands to code referring to
    // `DeveloperToolsSupport`, and a macro expansion can't import anything
    // itself, so that module has to already be in scope wherever
    // `#SCUIPreview` is written. Re-exporting it here covers every file that
    // imports this module. Unlike re-exporting SwiftUI, this introduces no
    // names that collide with SwiftCrossUI's.
    @_exported import DeveloperToolsSupport

    // The registration also refers to SwiftUI itself by name. Re-exporting the
    // whole module would make `ProposedViewSize` (among others) ambiguous
    // against SwiftCrossUI's, so export just the module name via a type alias
    // that shadows nothing.

    /// Stands in for the `SwiftUI` module inside a `#SCUIPreview` expansion.
    ///
    /// SwiftUI's preview registration expands to code that names
    /// `SwiftUI.View` and `SwiftUI.ViewBuilder` with the module spelled out, so
    /// those references only resolve where `SwiftUI` itself is in scope.
    /// Importing it in the expansion isn't possible, and re-exporting it from
    /// this module would make names it shares with SwiftCrossUI -- most
    /// visibly `ProposedViewSize` and `View` -- ambiguous in consumer code.
    ///
    /// The expansion instead aliases `SwiftUI` to this enum in the scope that
    /// holds the registration, which resolves the qualified references without
    /// putting anything into consumer scope.
    @_documentation(visibility: internal)
    public enum _SCUIPreviewSwiftUIShim {
        public typealias View = SwiftUI.View
        public typealias ViewBuilder = SwiftUI.ViewBuilder
    }

    /// SwiftUI's preview-registration macro, re-declared under a name of our
    /// own.
    ///
    /// The expansion of ``SCUIPreview(_:body:)`` has to contain SwiftUI's own
    /// preview registration, since that's what Xcode's canvas discovers, but it
    /// can't name that macro directly. A macro expansion can't introduce an
    /// `import`, so `#Preview` is in scope only if the file being compiled
    /// happens to import SwiftUI -- and consumers can't import SwiftUI
    /// unconditionally, because it doesn't exist on Linux or Windows.
    ///
    /// Pointing a declaration of our own at the same compiler plugin gives the
    /// expansion a name that's in scope wherever this module is imported. It
    /// mirrors the SwiftUI declaration it stands in for and has to keep
    /// matching it.
    @_documentation(visibility: internal)
    @freestanding(declaration, names: arbitrary)
    public macro _SCUIPreviewRegistration(
        _ name: String? = nil,
        @SwiftUICore.ContentBuilder body: @escaping @MainActor () -> any SwiftUICore.View
    ) = #externalMacro(module: "PreviewsMacros", type: "SwiftUIView")
#endif
