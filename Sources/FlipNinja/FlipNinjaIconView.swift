import AppKit
import SwiftUI

// MARK: - Vector laptop glyph (no image assets)

/// A laptop drawn with simple SwiftUI shapes, rotated to match the display.
/// The base sits below in landscape, on the left at 90°, and on the right at
/// 270° so the two portrait modes are visually distinct.
struct FlipNinjaGlyph: View {
    var angle: Int = 0

    private var isPortrait: Bool {
        angle == 90 || angle == 270
    }

    private var baseSide: CGFloat {
        switch angle {
        case 90: return -1
        case 270: return 1
        default: return 0
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let stroke = max(1, min(width, height) * 0.11)

            ZStack {
                if isPortrait {
                    RoundedRectangle(cornerRadius: width * 0.12, style: .continuous)
                        .strokeBorder(lineWidth: stroke)
                        .frame(width: width * 0.58, height: height * 0.78)
                    Capsule()
                        .frame(width: stroke, height: height * 0.62)
                        .offset(x: baseSide * width * 0.36)
                } else {
                    RoundedRectangle(cornerRadius: width * 0.12, style: .continuous)
                        .strokeBorder(lineWidth: stroke)
                        .frame(width: width * 0.82, height: height * 0.56)
                    Capsule()
                        .frame(width: width * 0.96, height: stroke)
                        .offset(y: height * 0.31)
                }
            }
            .frame(width: width, height: height)
        }
    }
}

// MARK: - Menu bar template image

@MainActor
enum FlipNinjaMenuBarIcon {
    /// Point size of the menu bar glyph (matches NSStatusItem.squareLength look).
    static let length: CGFloat = 18

    /// Renders the glyph into an `NSImage` flagged as a template, so it
    /// follows the menu bar tint automatically (dark/light/vibrancy).
    static func image(angle: Int, length: CGFloat = 18) -> NSImage {
        let view = FlipNinjaGlyph(angle: angle)
            .frame(width: length, height: length)
            .foregroundStyle(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4
        let image = renderer.nsImage ?? NSImage()
        image.size = NSSize(width: length, height: length)
        image.isTemplate = true
        image.accessibilityDescription = angle == 0
            ? "FlipNinja — landscape"
            : "FlipNinja — portrait \(angle)°"
        return image
    }
}

// MARK: - Application (Finder) icon

/// Full macOS app icon: a monitor panel with a silver bezel and a glossy
/// screen. The screen content is the FlipNinja wordmark rendered like a
/// crisp CLI prompt, rotated 90° with the display.
/// Rendered into Resources/AppIcon.icns by Scripts/make_appicon.swift.
struct FlipNinjaAppIconView: View {
    private let outerRadius: CGFloat = 220
    private let innerRadius: CGFloat = 170

    var body: some View {
        ZStack {
            // Monitor bezel / panel frame.
            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(white: 0.96),
                            Color(white: 0.78),
                            Color(white: 0.58)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 4)
                )

            // Screen recess.
            ZStack {
                RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.01, green: 0.04, blue: 0.14),
                                Color(red: 0.02, green: 0.13, blue: 0.34),
                                Color(red: 0.01, green: 0.28, blue: 0.34)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Faint CRT grid.
                Canvas { context, size in
                    var path = Path()
                    var y: CGFloat = 0
                    while y < size.height {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        y += 10
                    }
                    var x: CGFloat = 0
                    while x < size.width {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        x += 10
                    }
                    context.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 1)
                }

                // Glossy glass reflection across the upper-left.
                RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.03),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .center
                        )
                    )

                // Crisp CLI-style wordmark, rotated with the screen.
                Text("> FlipNinja_")
                    .font(.system(size: 108, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.80, green: 1.0, blue: 0.98))
                    .rotationEffect(.degrees(-90))
                    .fixedSize()

                // Inner screen edge.
                RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.55), lineWidth: 8)
            }
            .padding(70)
        }
        .frame(width: 1024, height: 1024)
        .clipShape(RoundedRectangle(cornerRadius: outerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.22), lineWidth: 3)
        )
    }
}

