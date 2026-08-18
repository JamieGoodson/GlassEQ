# GlassEQ alpha-0.9 Release Notes

This is a technical alpha for Apple Silicon Macs running macOS 26.

## Distribution Warning

This build is ad hoc-signed, not Developer ID signed, and not notarized. macOS Gatekeeper will reject it by default. Install only if you are comfortable testing ad hoc-signed macOS software and granting system audio capture permission.

## Changes Since alpha-0.8.1

- Playback now continuously corrects for independent capture and output clocks instead of eventually dropping or duplicating frames when nominal sample rates match but hardware clocks drift.
- GlassEQ learns a stable callback size and playback target for each output route. The Settings diagnostics show the active correction and allow the current device's calibration to be reset.
- Bidirectional Bluetooth headset modes retain their device-owned 24 or 16 kHz sample rate and use realtime sample-rate conversion with anti-alias filtering.
- Filters above a low-rate output's usable frequency ceiling are disabled in the realtime processor and identified in the editor.
- Multi-channel output devices play the stereo signal through their configured preferred stereo pair while leaving unrelated channels silent.
- Ring-buffer contention is retried within a bounded realtime budget, and capture-side dropped frames are now reported by diagnostics.
- Exact EQ values can be typed directly, and the parametric frequency control now uses a logarithmic scale.
- If the separate Settings helper cannot be launched, GlassEQ opens the same Settings interface inside the menu bar process.

## Included

- Menu bar app shell.
- Core Audio system output tap.
- Playback of processed audio to the current default output.
- Parametric EQ, 10-band graphic EQ, and 31-band graphic EQ profiles.
- AutoEQ / EqualizerAPO and REW text import.
- Per-output profile mappings by Core Audio device UID.
- Profile persistence under the GlassEQ sandbox container, with migration from legacy `~/Library/Application Support/GlassEQ` data.
- Settings helper app and local IPC for editing profiles from the menu bar app, with an in-process fallback.
- Audio route recovery after system sleep, screen wake, session unlock, and Bluetooth route teardown while the screen is locked.
- Route-specific playback buffering, clock correction, and local calibration history.
- Callback, frame-loss, occupancy, clock-correction, and latency diagnostics.

## Supported Alpha Target

- macOS 26.0 or newer.
- Apple Silicon / arm64 only.

## Known Issues

- Gatekeeper rejection is expected because the app is not notarized.
- System audio capture permission may require manual cleanup or retrying on test machines.
- Bluetooth and AirPods routes may still expose macOS Core Audio edge cases; report device model, macOS version, and steps to reproduce.
- AirPlay outputs are not yet supported.
- No automatic updates.
- No crash reporting.
- No notarized Developer ID build yet.
- No x86_64 build.

## Build Artifact

The release script writes:

```sh
.build/dist/GlassEQ-alpha-0.9-macos26-arm64.zip
.build/dist/GlassEQ-alpha-0.9-macos26-arm64.zip.sha256
```
