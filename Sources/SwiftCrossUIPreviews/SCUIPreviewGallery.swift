#if canImport(SwiftUI) && canImport(AppKit) && !targetEnvironment(macCatalyst)
    import Foundation

    import SwiftCrossUI

    /// The sample views used to demonstrate and verify ``SCUIPreview``.
    ///
    /// The demo previews, the snapshot tool, and the tests all render these same
    /// views, so what a preview shows and what a snapshot records can't drift
    /// apart.
    public enum SCUIPreviewGallery {
        /// A view in the gallery, paired with the size to render it at.
        public struct Entry {
            /// A filename-safe name identifying the entry.
            public let name: String

            /// Renders the entry to PNG data.
            ///
            /// Stored as a closure because each entry wraps a different view
            /// type.
            private let render: @MainActor () throws -> Data

            /// Creates a gallery entry.
            ///
            /// - Parameters:
            ///   - name: A filename-safe name identifying the entry.
            ///   - size: The size to propose when rendering the view.
            ///   - view: The view to render. It's rebuilt on each render so that
            ///     repeated renders don't share state.
            init(
                name: String,
                size: ProposedViewSize,
                view: @escaping @MainActor () -> some SwiftCrossUI.View
            ) {
                self.name = name
                render = {
                    try SCUIPreviewSnapshot.png(of: view(), size: size)
                }
            }

            /// Renders the entry to PNG data.
            ///
            /// - Returns: The rendered view, encoded as a PNG.
            /// - Throws: ``SCUIPreviewSnapshot/Error`` if the view can't be rendered.
            @MainActor
            public func renderPNG() throws -> Data {
                try render()
            }
        }

        /// Every view in the gallery.
        public static var entries: [Entry] {
            [
                Entry(name: "counter", size: .unspecified) {
                    CounterSample()
                },
                // Proposals only change the result for views that use the space
                // they're offered; `CounterSample` sizes to its content, so it
                // renders identically at any proposal.
                Entry(name: "banner-wide", size: ProposedViewSize(400, nil)) {
                    BannerSample()
                },
            ]
        }
    }

    /// A sample view that fills the width it's offered.
    ///
    /// Demonstrates that the proposed size reaches the hosted view's layout,
    /// which views that size to their content can't show.
    public struct BannerSample: SwiftCrossUI.View {
        /// Creates the sample view.
        public init() {}

        public var body: some SwiftCrossUI.View {
            SwiftCrossUI.VStack {
                SwiftCrossUI.Text("Fills the proposed width")
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    /// A sample view exercising text styling, a button, and stack layout.
    ///
    /// Deliberately not a single label, so that previews and snapshots show a
    /// real layout rather than a trivial one.
    public struct CounterSample: SwiftCrossUI.View {
        @SwiftCrossUI.State private var count = 0

        /// Creates the sample view.
        public init() {}

        public var body: some SwiftCrossUI.View {
            SwiftCrossUI.VStack {
                SwiftCrossUI.Text("SwiftCrossUI in Xcode")
                    .font(.title)
                SwiftCrossUI.Text("Count: \(count)")
                SwiftCrossUI.Button("Increment") {
                    count += 1
                }
            }
            .padding()
        }
    }
#endif
