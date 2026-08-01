import MacroToolkit
import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `#SCUIPreview` into a SwiftUI preview registration on the platforms
/// that have a preview canvas, and into nothing everywhere else.
///
/// Expanding to nothing off-Apple is what lets consumers write `#SCUIPreview`
/// in ordinary source files, with no conditional compilation of their own, and
/// still have those files build on Linux and Windows.
///
/// Two details of the expansion are forced by the macro system rather than
/// chosen:
///
/// - The gate tests `os(...)` rather than `canImport(SwiftUI)`. `canImport`
///   evaluates to false inside a macro expansion buffer even on platforms where
///   the module is present, so gating on it would silently discard every
///   preview.
/// - The registration is nested inside a uniquely-named enum. Freestanding
///   declaration macros have to declare the names they introduce and can't
///   introduce arbitrary ones at file scope, but SwiftUI's `#Preview`
///   introduces a mangled name that can't be spelled ahead of time. Names from
///   `makeUniqueName` are exempt from that requirement, so nesting the
///   registration inside one satisfies it. Xcode discovers previews through
///   conformance metadata rather than by scope, so the nesting doesn't hide
///   them from the canvas.
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

        return [
            """
            #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
                enum \(context.makeUniqueName("SCUIPreview")) {
                    typealias SwiftUI = SwiftCrossUIPreviews._SCUIPreviewSwiftUIShim

                    #_SCUIPreviewRegistration(\(raw: name)) {
                        SwiftCrossUIPreviews.SCUIPreview \(raw: body.description)
                    }
                }
            #endif
            """
        ]
    }
}
