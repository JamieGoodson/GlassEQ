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
        .library(name: "GlassEQAudio", targets: ["GlassEQAudio"]),
        .library(name: "GlassEQSettingsIPC", targets: ["GlassEQSettingsIPC"]),
        .executable(name: "GlassEQ", targets: ["GlassEQApp"])
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
        .target(
            name: "GlassEQSettingsIPC",
            dependencies: ["GlassEQCore"]
        ),
        .executableTarget(
            name: "GlassEQApp",
            dependencies: [
                "GlassEQCore",
                "GlassEQAudio",
                "GlassEQSettingsIPC"
            ],
            exclude: [
                "Info.plist"
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Security")
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
        ),
        .testTarget(
            name: "GlassEQAppTests",
            dependencies: [
                "GlassEQApp",
                "GlassEQAudio",
                "GlassEQCore",
                "GlassEQSettingsIPC"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
