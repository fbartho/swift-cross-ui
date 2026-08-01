import MacroToolkit
import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `#SCUIPreview` into a preview registration on the platforms that
/// have a preview canvas, and into nothing everywhere else.
///
/// Expanding to nothing off-Apple is what lets consumers write `#SCUIPreview`
/// in ordinary source files, with no conditional compilation of their own, and
/// still have those files build on Linux and Windows.
///
/// The expansion emits a `DeveloperToolsSupport.PreviewRegistry` conformance
/// directly rather than delegating to SwiftUI's `#Preview`. Delegating would
/// nest SwiftUI's expansion inside ours, and Xcode's canvas identifies a
/// preview by the mangled name of the registry type, which encodes the shape of
/// the expansion that produced it. A nested expansion mangles one frame deeper
/// than a bare `#Preview` does, so the canvas fails to match it and reports
/// "Missing Preview". Emitting the registry ourselves keeps the registration at
/// the same depth as SwiftUI's.
///
/// Two further details of the expansion are forced by the macro system rather
/// than chosen:
///
/// - The gate tests `os(...)` rather than `canImport(SwiftUI)`. `canImport`
///   evaluates to false inside a macro expansion buffer even on platforms where
///   the module is present, so gating on it would silently discard every
///   preview.
/// - The registry type is named with `makeUniqueName` rather than spelled out.
///   Freestanding declaration macros have to declare the names they introduce
///   and can't introduce arbitrary ones at file scope; names from
///   `makeUniqueName` are exempt. The label passed to it becomes part of the
///   mangled name, so it has to match the one SwiftUI's own expansion uses.
public struct SCUIPreviewMacro: DeclarationMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let body = node.trailingClosure else {
            throw MacroError("#SCUIPreview expects a trailing closure containing a view")
        }

        // SwiftUI's `#Preview` takes an optional display name as its first
        // argument, so pass along whatever the caller wrote.
        let name = node.arguments.map(\.description).joined(separator: ", ")

        // The registry reports the source position of the macro itself, which
        // is what the canvas uses to associate a registration with the call
        // site it came from.
        let location = context.location(of: node, at: .afterLeadingTrivia, filePathMode: .fileID)
        let fileID = location?.file ?? "\"\""
        let line = location?.line ?? "0"
        let column = location?.column ?? "0"

        // Matches the label in SwiftUI's expansion, so that the two mangle
        // identically.
        let registry = context.makeUniqueName("PreviewRegistry")

        return [
            """
            #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
                @available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, watchOS 10.0, *)
                nonisolated struct \(registry): DeveloperToolsSupport.PreviewRegistry {
                    static var fileID: String {
                        \(raw: fileID)
                    }
                    static var line: Int {
                        \(raw: line)
                    }
                    static var column: Int {
                        \(raw: column)
                    }

                    @MainActor static func makePreview() throws -> DeveloperToolsSupport.Preview {
                        DeveloperToolsSupport.Preview(\(raw: name)) {
                            SwiftCrossUIPreviews.SCUIPreview \(raw: body.description)
                        }
                    }
                }
            #endif
            """
        ]
    }
}
