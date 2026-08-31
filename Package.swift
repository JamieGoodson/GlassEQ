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
        .library(name: "GlassEQSettingsUI", targets: ["GlassEQSettingsUI"]),
        .library(name: "GlassEQMenuBarUI", targets: ["GlassEQMenuBarUI"]),
        .library(name: "GlassEQAppPreviews", targets: ["GlassEQAppPreviews"]),
        .executable(name: "GlassEQ", targets: ["GlassEQApp"]),
        .executable(name: "GlassEQSettings", targets: ["GlassEQSettings"]),
        .executable(name: "GlassEQDiagnostics", targets: ["GlassEQDiagnostics"])
    ],
    targets: [
        .target(
            name: "GlassEQCore"
        ),
        .target(
            name: "GlassEQAudio",
            dependencies: ["GlassEQCore"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .target(
            name: "GlassEQSettingsIPC",
            dependencies: ["GlassEQCore"]
        ),
        .target(
            name: "GlassEQSettingsUI",
            dependencies: [
                "GlassEQCore",
                "GlassEQSettingsIPC"
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
        .target(
            name: "GlassEQMenuBarUI",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "GlassEQApp",
            dependencies: [
                "GlassEQCore",
                "GlassEQAudio",
                "GlassEQMenuBarUI",
                "GlassEQSettingsIPC",
                "GlassEQSettingsUI"
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
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .target(
            name: "GlassEQAppPreviews",
            dependencies: ["GlassEQMenuBarUI"],
            linkerSettings: [
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "GlassEQSettings",
            dependencies: [
                "GlassEQSettingsIPC",
                "GlassEQSettingsUI"
            ],
            exclude: [
                "Info.plist"
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "GlassEQDiagnostics",
            dependencies: [
                "GlassEQCore",
                "GlassEQAudio"
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
                "GlassEQSettingsIPC",
                "GlassEQSettingsUI"
            ]
        ),
        .testTarget(
            name: "GlassEQSettingsIPCTests",
            dependencies: [
                "GlassEQCore",
                "GlassEQSettings",
                "GlassEQSettingsIPC",
                "GlassEQSettingsUI"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
