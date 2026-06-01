// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "GlassEQ",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "GlassEQCore", targets: ["GlassEQCore"]),
        .library(name: "GlassEQAudio", targets: ["GlassEQAudio"])
    ],
    targets: [
        .target(
            name: "GlassEQCore"
        ),
        .target(
            name: "GlassEQAudio",
            dependencies: ["GlassEQCore"],
            linkerSettings: [
                .linkedFramework("CoreAudio")
            ]
        ),
        .testTarget(
            name: "GlassEQCoreTests",
            dependencies: ["GlassEQCore"]
        ),
        .testTarget(
            name: "GlassEQAudioTests",
            dependencies: [
                "GlassEQAudio",
                "GlassEQCore"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
