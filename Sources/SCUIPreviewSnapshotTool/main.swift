#if canImport(SwiftUI) && canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
    import Foundation

    import SwiftCrossUI
    import SwiftCrossUIPreviews

    // Renders the gallery to PNGs on disk. Xcode's preview canvas can't be
    // captured programmatically, so this renders the same views through the same
    // hosting path that SCUIPreview uses, giving a repeatable way to produce
    // images for documentation and for spotting rendering regressions.
    //
    // Usage: swift run SCUIPreviewSnapshotTool [output-directory]

    MainActor.assumeIsolated {
        let arguments = CommandLine.arguments
        let outputDirectory = URL(
            fileURLWithPath: arguments.count > 1 ? arguments[1] : "snapshots",
            isDirectory: true
        )

        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )

            for entry in SCUIPreviewGallery.entries {
                let data = try entry.renderPNG()
                let url = outputDirectory.appendingPathComponent("\(entry.name).png")
                try data.write(to: url)
                print("Wrote \(url.path)")
            }
        } catch {
            FileHandle.standardError.write(
                Data("error: \(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
    }
#else
    #error("SCUIPreviewSnapshotTool is only supported on macOS")
#endif
