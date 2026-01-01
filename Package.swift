// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "osaurus-macos-use",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "osaurus-macos-use", type: .dynamic, targets: ["osaurus_macos_use"])
    ],
    targets: [
        .target(
            name: "osaurus_macos_use",
            path: "Sources/osaurus_macos_use",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
