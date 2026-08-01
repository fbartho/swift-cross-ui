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

    @Test("Expansion registers the preview directly")
    func testExpansionRegistersPreview() throws {
        let expansion = try expand(
            """
            #SCUIPreview {
                Text("Hello")
            }
            """
        )

        // Xcode discovers previews through `PreviewRegistry` conformances, and
        // matches them by mangled name. Delegating to SwiftUI's `#Preview`
        // would nest its expansion inside ours and mangle a frame deeper than
        // the canvas expects, so the registry is emitted here instead, with
        // the view wrapped in the type that bridges SwiftCrossUI to SwiftUI.
        #expect(expansion.contains(": DeveloperToolsSupport.PreviewRegistry"))
        #expect(expansion.contains("DeveloperToolsSupport.Preview"))
        #expect(expansion.contains("SwiftCrossUIPreviews.SCUIPreview"))
        #expect(expansion.contains("Text(\"Hello\")"))
    }

    @Test("Registry reports the source position of the macro")
    func testRegistryReportsSourcePosition() throws {
        let expansion = try expand(
            """
            #SCUIPreview {
                Text("Hello")
            }
            """
        )

        // The canvas associates a registration with the call site it came
        // from, so the registry has to carry all three position properties.
        #expect(expansion.contains("static var fileID: String"))
        #expect(expansion.contains("static var line: Int"))
        #expect(expansion.contains("static var column: Int"))
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

        #expect(expansion.contains("DeveloperToolsSupport.Preview(\"Counter\")"))
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

        #expect(expansion.contains("DeveloperToolsSupport.Preview()"))
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
