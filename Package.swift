// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "GlassEQ",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "GlassEQCore", targets: ["GlassEQCore"])
    ],
    targets: [
        .target(
            name: "GlassEQCore"
        ),
        .testTarget(
            name: "GlassEQCoreTests",
            dependencies: ["GlassEQCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
