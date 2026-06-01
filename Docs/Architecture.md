# GlassEQ Architecture

## Audio Ownership Model

macOS owns output switching. GlassEQ observes the default output device and follows it. The app never asks the user to choose a physical output inside GlassEQ.

The runtime flow is:

1. Discover current default output device and UID.
2. Load the mapped profile for that output UID.
3. Build a private Core Audio system tap that excludes GlassEQ itself.
4. Mute tapped dry output while the tap is active.
5. Process tap buffers through the active EQ configuration.
6. Replay processed audio to the current default output device.
7. Tear down and rebuild the graph when macOS changes the default output.

## Real-Time Rules

The audio render path must not allocate, lock, touch disk, log, parse text, mutate SwiftUI state, or use Combine. UI and import work produce immutable profile/config values that are swapped into the renderer outside the callback.

## Current Implementation Status

This repository contains the SwiftPM project, DSP engine, importers, profile persistence, menu bar shell, Core Audio tap capture, a preallocated stereo ring buffer, and playback to the current default output device. The Core Audio bridge is intentionally isolated under `GlassEQAudio` so device-format support and hardware QA can be hardened without disturbing UI/profile code.

## Diagnostics

Run a short smoke test against the current macOS default output:

```sh
swift run GlassEQDiagnostics 2
```

The command prints output device metadata and post-run callback metrics:

- Captured frames from the private Core Audio tap.
- Played frames written to the default output device.
- Playback underrun frames.

The diagnostic follows the current macOS output device and does not switch outputs itself.

By default, diagnostics redact local device names, UIDs, and transport identifiers. Add `--verbose` when collecting full local debug output for yourself:

```sh
swift run GlassEQDiagnostics --verbose 2
```

`--intentional-crash-after-start` is reserved for crash-reporting and cleanup validation. It starts the engine, prints that the crash-test path was requested, flushes stdout, and aborts deliberately.

## Profile Storage And Settings Helper

Profile data belongs to the main app sandbox and is migrated by the main app through `container-migration.plist`. The settings helper does not share profile storage and does not need an app-group entitlement; it receives snapshots and sends commands over the private stdin/stdout IPC session launched by GlassEQ.
