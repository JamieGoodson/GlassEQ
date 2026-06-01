# GlassEQ alpha-0.5 Release Notes

This is a technical alpha for Apple Silicon Macs running macOS 26.

## Distribution Warning

This build is ad hoc-signed, not Developer ID signed, and not notarized. macOS Gatekeeper will reject it by default. Install only if you are comfortable testing ad hoc-signed macOS software and granting system audio capture permission.

## Included

- Menu bar app shell.
- Core Audio system output tap.
- Playback of processed audio to the current default output.
- Parametric EQ, 10-band graphic EQ, and 31-band graphic EQ profiles.
- AutoEQ / EqualizerAPO and REW text import.
- Per-output profile mappings by Core Audio device UID.
- Profile persistence under the GlassEQ sandbox container, with migration from legacy `~/Library/Application Support/GlassEQ` data.
- Settings helper app and local IPC for editing profiles from the menu bar app.
- Audio route recovery after system sleep, screen wake, session unlock, and Bluetooth route teardown while the screen is locked.
- More conservative built-in speaker buffering to avoid steady-state playback underruns and distortion.
- Basic callback metrics and diagnostics tooling.

## Supported Alpha Target

- macOS 26.0 or newer.
- Apple Silicon / arm64 only.

## Known Issues

- Gatekeeper rejection is expected because the app is not notarized.
- System audio capture permission may require manual cleanup or retrying on test machines.
- Bluetooth and AirPods routes may still expose macOS Core Audio edge cases; report device model, macOS version, and steps to reproduce.
- No automatic updates.
- No crash reporting.
- No notarized Developer ID build yet.
- No x86_64 build.

## Build Artifact

The release script writes:

```sh
.build/dist/GlassEQ-alpha-0.5-macos26-arm64.zip
.build/dist/GlassEQ-alpha-0.5-macos26-arm64.zip.sha256
```
