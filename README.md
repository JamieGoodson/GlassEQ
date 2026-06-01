# GlassEQ

GlassEQ is a native macOS 26 system-output equalizer prototype written in Swift 6.

## Alpha Status

Current alpha builds are for technical testers only. They are ad hoc-signed, not Developer ID signed, not notarized, Apple Silicon only, and tested only on macOS 26.

macOS Gatekeeper will reject the app by default. Testers need to be comfortable opening an ad hoc-signed app, granting system audio capture permission, collecting diagnostics, and reporting hardware-specific audio issues.

For browser-downloaded alpha builds, first launch requires System Settings > Privacy & Security > allow GlassEQ to open.

See [Docs/AlphaTesting.md](Docs/AlphaTesting.md), [Docs/Distribution.md](Docs/Distribution.md), and [Docs/ReleaseNotes-alpha-0.6.md](Docs/ReleaseNotes-alpha-0.6.md) before installing a build.

The first implementation milestone focuses on the audio core:

- Core Audio default-output discovery and change monitoring.
- Core Audio process/system tap capture and playback to the current default output.
- Real-time-oriented EQ DSP with parametric, 10-band graphic, and 31-band graphic profiles.
- AutoEQ / EqualizerAPO and REW text import.
- Per-output profile mapping by Core Audio device UID.
- SwiftUI menu bar app shell.

## Pinned Toolchain

- Xcode: 26.5, build 17F42.
- SDK: macOS 26.5.
- Swift: Xcode-bundled Swift 6.3 / local Swift 6.3.1 command-line toolchain.
- SwiftPM: `// swift-tools-version: 6.3`.
- Deployment target: macOS 26.0.

## Local Setup

After installing Xcode, accept the license in Terminal:

```sh
sudo xcodebuild -license
```

Then verify and test:

```sh
xcodebuild -version
swift --version
swift test
swift run GlassEQ
swift run GlassEQDiagnostics 2
```

## Alpha Packaging

Create an ad hoc-signed technical-alpha artifact:

```sh
./Scripts/build-release-app.sh
```

The script builds a release app bundle, embeds the app icon, ad hoc-signs the bundle, and writes a zip under `.build/dist/`.

The expected Gatekeeper assessment result is rejection because the alpha is not Developer ID signed or notarized:

```sh
codesign -d --entitlements :- .build/release-app/GlassEQ.app
spctl --assess --type execute --verbose=4 .build/release-app/GlassEQ.app
```

The entitlements output should include `com.apple.security.app-sandbox` and `com.apple.security.device.audio-input`, both set to `true`.

## Product Boundaries

GlassEQ intentionally does not implement per-app routing, a virtual output selector, plugin hosting, microphone recording, telemetry, or cloud sync.

## License

GlassEQ is released under the MIT License.

Copyright (c) 2026 Juho Koskela.
