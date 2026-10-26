// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Deckhand",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StreamDockMCP",
            path: "Sources/StreamDockMCP",
            linkerSettings: []
        ),
        .executableTarget(
            name: "Deckhand",
            path: "Sources/Deckhand",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
            ]
        )
    ]
)
