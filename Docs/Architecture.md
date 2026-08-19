# GlassEQ Architecture

## Audio Ownership Model

macOS owns output switching. GlassEQ observes the default output device and follows it. The app never asks the user to choose a physical output inside GlassEQ.

The runtime flow is:

1. Discover current default output device and UID.
2. Load the mapped profile for that output UID.
3. If GlassEQ is globally disabled or the output UID is configured for automatic bypass, leave the audio graph stopped and let macOS play the dry output normally.
4. Otherwise, build a private Core Audio system tap that excludes GlassEQ itself.
5. Mute tapped dry output while the tap is active.
6. Process tap buffers through the active EQ configuration.
7. Replay processed audio to the current default output device.
8. Tear down and rebuild the graph when macOS changes the default output.

## Real-Time Rules

The audio render path must not allocate, lock, touch disk, log, parse text, mutate SwiftUI state, or use Combine. UI and import work produce immutable profile/config values that are swapped into the renderer outside the callback.

## Current Implementation Status

This repository contains the SwiftPM project, DSP engine, importers, profile persistence, menu bar shell, Core Audio tap capture, a preallocated stereo ring buffer, and playback to the current default output device. The Core Audio bridge is intentionally isolated under `GlassEQAudio` so device-format support and hardware QA can be hardened without disturbing UI/profile code.

## Adaptive Playback Buffering

Normal-rate outputs start at the lowest callback-size step GlassEQ supports. Each device UID and sample-rate pair learns its hardware callback size plus a separate stable servo target for every callback size it has exercised. An underrun adds one 64-frame capture period to the current target, up to three capture periods beyond the callback; only another underrun at that ceiling increases the hardware callback. Excessive backlog is trimmed during reprime and does not modify the device calibration. An output timestamp discontinuity increases the hardware callback immediately because more queued audio cannot repair a missed device deadline. A callback increase starts from the target already learned for that quantum, or from one callback plus one capture period when the quantum is new, instead of carrying forward the previous quantum's reservoir. A candidate operating point must run for 60 seconds without another instability before it becomes stable. On a later engine session, a stable target may probe one 64-frame step lower; a failed lower target is remembered and is not retried until the device calibration is reset. Hardware callbacks never decrease automatically. The bounded local history records stabilization and meaningful instability transitions; repeated unresolved instability at the same operating point is deduplicated in memory without rereading or rewriting the calibration file. No calibration data leaves the Mac. Existing learned scalar targets migrate to the operating point for their callback size. Diagnostics can clear every learned sample-rate variant for the current device UID and immediately restart its calibration without affecting other outputs.

Every route runs the occupancy servo and four-point Hermite resampler. Matching the tap and output's nominal sample rates does not guarantee that their hardware clocks advance identically, so the servo applies a small continuous rate correction instead of eventually dropping or duplicating frames. Output timestamp discontinuities and occupancy jumps beyond four callback periods re-prime directly to the route target while preserving the learned correction; step backlogs are never left for the ppm-scale servo to drain. Bidirectional Bluetooth headset modes retain their device-owned 24 or 16 kHz rate and add Audio Toolbox's realtime-safe PCM converter after the Hermite stage; returning to a normal-rate route disposes that converter and resets the clock pair. Low-sample-rate routes keep conservative fixed callback buffering instead of running the calibration ladder. EQ coefficients remain calculated at the tap's processing rate, while filters above the output route's usable-frequency ceiling receive identity coefficients so runtime behavior matches the editor warning.

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

Diagnostics print full local device names, UIDs, and transport identifiers:

```sh
swift run GlassEQDiagnostics 2
```

`--intentional-crash-after-start` is reserved for crash-reporting and cleanup validation. It starts the engine, prints that the crash-test path was requested, flushes stdout, and aborts deliberately.

## Profile Storage And Settings Helper

Profiles, the global manual bypass flag, and the automatic per-output bypass UID list belong to the main app sandbox and are migrated by the main app through `container-migration.plist`. Bypass state is application-level and never part of an EQ profile. The menu can temporarily override an automatic rule for the current output visit; that exception is in-memory only and is cleared when the default output UID changes, leaving the saved rule untouched. The settings helper does not share this storage and does not need an app-group entitlement; it receives snapshots and sends commands over the private stdin/stdout IPC session launched by GlassEQ. Its profile editor opens automatic device bypass in a dedicated global window backed by the same IPC model.
