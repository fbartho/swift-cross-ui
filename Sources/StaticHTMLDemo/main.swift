import Foundation
import StaticHTMLBackend
import SwiftCrossUI

// A page exercising each of the three markup layers: headings derived from
// declared text styles, an explicit element via the escape hatch, and
// undeclared content that falls through to divs.
struct DemoPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SwiftCrossUI to Static HTML")
                .font(.largeTitle)

            Text("Rendered on the build host. No wasm, no runtime, no script.")

            HStack(spacing: 8) {
                Button("Home") {}
                Button("Docs") {}
                Button("About") {}
            }
            .htmlTag(.nav)

            Color.blue
                .frame(width: 320, height: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Why static rendering?")
                    .font(.title)

                Text("The layout engine already runs headlessly.")
                Text("Backends only ever receive resolved geometry.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Colors follow the reader")
                    .font(.title2)

                Text("Foreground colors resolve per scheme.")
                Text("Try toggling your system appearance.")
            }

            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("Column A")
                        .font(.title3)

                    Text("a1")
                    Text("a2")
                }
                VStack(spacing: 4) {
                    Text("Column B")
                        .font(.title3)

                    Text("b1")
                    Text("b2")
                }
            }
        }
        .padding(24)
    }
}

let outputPath =
    CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : FileManager.default.currentDirectoryPath + "/static-html-demo.html"

let result = MainActor.assumeIsolated {
    StaticHTMLRenderer.render(
        DemoPage(),
        context: "SwiftCrossUI Static HTML",
        size: SIMD2(800, 600)
    )
}

try result.html.write(toFile: outputPath, atomically: true, encoding: .utf8)

print("Wrote \(outputPath) (\(result.html.count) bytes, \(result.size.x)x\(result.size.y))")
if result.geometryMismatches.isEmpty {
    print("Geometry is color scheme invariant")
} else {
    print("Geometry differed between color schemes:")
    for mismatch in result.geometryMismatches {
        print("  \(mismatch.tag): light \(mismatch.lightSize), dark \(mismatch.darkSize)")
    }
}
