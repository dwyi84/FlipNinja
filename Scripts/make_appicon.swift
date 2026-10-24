// Renders the 1024 × 1024 app icon master (FlipNinjaAppIconView) to a PNG.
//
// Usage:
//   swiftc Scripts/make_appicon.swift Sources/FlipNinja/FlipNinjaIconView.swift \
//       -o build/make_appicon && build/make_appicon build/AppIcon-1024.png
//
// The Makefile downscales the master into an .iconset and packs it with
//   iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

import AppKit
import SwiftUI

@main
@MainActor
struct MakeAppIcon {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(
                "usage: make_appicon <output.png>\n".data(using: .utf8)!
            )
            exit(2)
        }
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

        let renderer = ImageRenderer(content: FlipNinjaAppIconView())
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 1024, height: 1024)

        guard let cgImage = renderer.cgImage else {
            FileHandle.standardError.write(
                "failed to render icon\n".data(using: .utf8)!
            )
            exit(1)
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(
                "failed to encode PNG\n".data(using: .utf8)!
            )
            exit(1)
        }

        do {
            try png.write(to: outputURL)
            print("wrote \(outputURL.path)")
        } catch {
            FileHandle.standardError.write(
                "cannot write \(outputURL.path): \(error.localizedDescription)\n"
                    .data(using: .utf8)!
            )
            exit(1)
        }
    }
}
