#if canImport(SwiftUI) && canImport(AppKit) && !targetEnvironment(macCatalyst)
    import DeveloperToolsSupport
    import SwiftUI
    import Testing

    import SwiftCrossUI
    import SwiftCrossUIPreviews

    // Reproduces what Xcode's preview agent does with a registration, so that
    // failures in the registration itself can be told apart from failures in
    // the canvas.
    //
    // The canvas builds the registry type, calls `makePreview()` on it, and
    // renders the result. Both previews below are written the same way a
    // consumer writes them, so the registries they produce are the same ones
    // the canvas finds.

    /// A SwiftCrossUI view with state, matching the one in SCUIPreviewProbe.
    private struct CounterProbe: SwiftCrossUI.View {
        @SwiftCrossUI.State private var count = 0

        var body: some SwiftCrossUI.View {
            VStack {
                SwiftCrossUI.Text("count: \(count)")
                SwiftCrossUI.Button("Increment") {
                    count += 1
                }
            }
        }
    }

    @Suite("Preview registration")
    struct RegistrationTests {
        @Test("A registration built by the overload can be made")
        @MainActor
        func testOverloadRegistrationMakesPreview() throws {
            // Mirrors the probe's preview 2. If Xcode's canvas reports a
            // runtime error for that preview, calling the same entry point
            // here should reproduce it.
            _ = try DeveloperToolsSupport.Preview {
                SwiftCrossUIPreviews.SCUIPreview {
                    CounterProbe()
                }
            }
        }

        @Test("A registration wrapping a SwiftUI view can be made")
        @MainActor
        func testSwiftUIRegistrationMakesPreview() throws {
            // The control, mirroring the probe's preview 1. If this fails too,
            // the problem is environmental rather than ours.
            _ = try DeveloperToolsSupport.Preview {
                SwiftUI.Text("anchor")
            }
        }

        @Test("Both registries' previews can be made through the protocol")
        @MainActor
        func testRegistriesMakePreviewThroughProtocol() throws {
            // The canvas reaches a registration through the protocol witness
            // rather than the concrete type, so exercise that path for a
            // SwiftCrossUI body and a SwiftUI one. Local registry types stand
            // in for the generated ones, which can't be named in source.
            struct CrossRegistry: DeveloperToolsSupport.PreviewRegistry {
                static let fileID = "SCUIPreviewProbe/CanvasProbe.swift"
                static let line = 60
                static let column = 5

                @MainActor static func makePreview() throws
                    -> DeveloperToolsSupport.Preview
                {
                    DeveloperToolsSupport.Preview {
                        SwiftCrossUIPreviews.SCUIPreview {
                            CounterProbe()
                        }
                    }
                }
            }

            struct SwiftUIRegistry: DeveloperToolsSupport.PreviewRegistry {
                static let fileID = "SCUIPreviewProbe/CanvasProbe.swift"
                static let line = 54
                static let column = 5

                @MainActor static func makePreview() throws
                    -> DeveloperToolsSupport.Preview
                {
                    DeveloperToolsSupport.Preview {
                        SwiftUI.Text("anchor")
                    }
                }
            }

            let registries: [any DeveloperToolsSupport.PreviewRegistry.Type] = [
                SwiftUIRegistry.self,
                CrossRegistry.self,
            ]
            for registry in registries {
                _ = try registry.makePreview()
            }
        }

        @Test("A view reached through the registration's existential renders")
        @MainActor
        func testExistentialViewRenders() throws {
            // The registration hands the preview an `any SwiftUICore.View`, so
            // the canvas renders SCUIPreview through an existential rather than
            // as a concrete type. Force that same erasure and then drive
            // AppKit's rendering of it, which is what the canvas ends up doing.
            let erased: any SwiftUI.View = SwiftCrossUIPreviews.SCUIPreview {
                CounterProbe()
            }

            let controller = SwiftUI.NSHostingController(
                rootView: SwiftUI.AnyView(erased)
            )
            let view = controller.view
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)

            // Force a layout and display pass. A registration that builds but
            // can't render will fail here rather than at construction.
            view.layoutSubtreeIfNeeded()
            let representation = try #require(
                view.bitmapImageRepForCachingDisplay(in: view.bounds),
                "Could not create a bitmap for the hosted preview"
            )
            view.cacheDisplay(in: view.bounds, to: representation)

            #expect(view.frame.width > 0)
        }
    }
#endif
