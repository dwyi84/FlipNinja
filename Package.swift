// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FlipNinja",
    platforms: [
        .macOS("14.0")
    ],
    targets: [
        .executableTarget(
            name: "FlipNinja",
            path: "Sources/FlipNinja",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
