import SwiftCrossUIMacrosPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

fileprivate let testMacros: [String: MacroSpec] = [
    "SCUIPreview": MacroSpec(type: SCUIPreviewMacro.self)
]

@Suite("Testing #SCUIPreview Macro")
struct SCUIPreviewMacroTests {
    // The container enum is named with `makeUniqueName`, which mangles in the
    // name of the module and file being compiled, so these tests pin the parts
    // of the expansion that carry meaning rather than matching a whole buffer.

    @Test("Expansion is gated on the platforms that have a preview canvas")
    func testExpansionIsGated() throws {
        let expansion = try expand(
            """
            #SCUIPreview {
                Text("Hello")
            }
            """
        )

        // The gate has to test `os(...)`. `canImport(SwiftUI)` evaluates to
        // false inside an expansion buffer even where SwiftUI is available,
        // which would silently drop every preview.
        #expect(
            expansion.contains(
                "#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)"
            )
        )
        #expect(!expansion.contains("canImport"))
        #expect(expansion.contains("#endif"))
    }

    @Test("Expansion registers the preview with SwiftUI")
    func testExpansionRegistersPreview() throws {
        let expansion = try expand(
            """
            #SCUIPreview {
                Text("Hello")
            }
            """
        )

        // Xcode discovers previews through SwiftUI's own registration, so the
        // expansion has to bottom out in it, with the view wrapped in the
        // type that bridges SwiftCrossUI to SwiftUI.
        #expect(expansion.contains("#_SCUIPreviewRegistration"))
        #expect(expansion.contains("SwiftCrossUIPreviews.SCUIPreview"))
        #expect(expansion.contains("Text(\"Hello\")"))
    }

    @Test("Expansion aliases SwiftUI so that the registration resolves")
    func testExpansionAliasesSwiftUI() throws {
        let expansion = try expand(
            """
            #SCUIPreview {
                Text("Hello")
            }
            """
        )

        // SwiftUI's registration names `SwiftUI.View` and
        // `SwiftUI.ViewBuilder` with the module spelled out, and an expansion
        // can't introduce the import that would make those resolve.
        #expect(
            expansion.contains(
                "typealias SwiftUI = SwiftCrossUIPreviews._SCUIPreviewSwiftUIShim"
            )
        )
    }

    @Test("Display name is passed through to the registration")
    func testDisplayNameIsPassedThrough() throws {
        let expansion = try expand(
            """
            #SCUIPreview("Counter") {
                CounterSample()
            }
            """
        )

        #expect(expansion.contains("#_SCUIPreviewRegistration(\"Counter\")"))
    }

    @Test("Omitted display name expands to an empty argument list")
    func testOmittedDisplayName() throws {
        let expansion = try expand(
            """
            #SCUIPreview {
                CounterSample()
            }
            """
        )

        #expect(expansion.contains("#_SCUIPreviewRegistration()"))
    }

    @Test("Macro requires a trailing closure")
    func testRequiresTrailingClosure() throws {
        let declaration = try #require(
            DeclSyntax("#SCUIPreview(\"Counter\")").as(MacroExpansionDeclSyntax.self)
        )

        #expect(throws: (any Error).self) {
            try SCUIPreviewMacro.expansion(
                of: declaration,
                in: BasicMacroExpansionContext()
            )
        }
    }

    /// Expands a single `#SCUIPreview` declaration and returns the expanded
    /// code.
    private func expand(_ source: SyntaxNodeString) throws -> String {
        let declaration = try #require(
            DeclSyntax("\(source)").as(MacroExpansionDeclSyntax.self)
        )
        let expansion = try SCUIPreviewMacro.expansion(
            of: declaration,
            in: BasicMacroExpansionContext()
        )
        return expansion.map { $0.description }.joined(separator: "\n")
    }
}
