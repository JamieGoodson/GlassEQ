import CoreAudio
import Foundation
import GlassEQAudio
import GlassEQCore
import GlassEQSettingsIPC
import Testing
@testable import GlassEQApp

@MainActor
@Suite
struct GlassEQAppModelLifecycleTests {
    @Test
    func retryRunningEngineUpdatesActiveProfileWithoutDefaultLookup() async {
        let runningOutput = makeOutput(uid: "running-output", name: "Running Output")
        let defaultOutput = makeOutput(uid: "default-output", name: "Default Output")
        let engine = FakeAudioEngine()
        engine.state = .running(output: runningOutput)
        let lookup = FakeDefaultOutputLookup(.success(defaultOutput))
        let model = makeModel(engine: engine, lookup: lookup)

        model.retryAudioEngine()
        await waitUntil {
            model.lifecycleState == .running && engine.updateCalls.count == 1
        }

        #expect(engine.updateCalls.map(\.id) == [model.activeProfile.id])
        #expect(engine.startCalls.isEmpty)
        #expect(lookup.defaultOutputCalls == 0)
        #expect(model.currentOutputUID == runningOutput.uid)
        #expect(model.currentOutputName == runningOutput.name)
        #expect(model.isRunning)
        #expect(model.lifecycleState == .running)
    }

    @Test
    func retryStoppedEngineQueriesDefaultOutputAndStarts() async {
        let output = makeOutput(uid: "default-output", name: "Default Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let model = makeModel(engine: engine, lookup: lookup)

        model.retryAudioEngine()
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        #expect(lookup.defaultOutputCalls == 1)
        #expect(engine.updateCalls.isEmpty)
        #expect(engine.startCalls.map(\.output) == [output])
        #expect(model.currentOutputUID == output.uid)
        #expect(model.currentOutputName == output.name)
        #expect(model.isRunning)
        #expect(model.lifecycleState == .running)
    }

    @Test
    func retryFailedEngineKeepsOutputMetadataWhenStartFails() async {
        let output = makeOutput(uid: "metadata-output", name: "Metadata Output")
        let engine = FakeAudioEngine()
        engine.state = .failed("Previous failure")
        engine.startError = TestAudioError.startFailed
        let lookup = FakeDefaultOutputLookup(.success(output))
        let model = makeModel(engine: engine, lookup: lookup)

        model.retryAudioEngine()
        await waitUntil {
            lookup.defaultOutputCalls == 1
                && engine.startCalls.count == 1
                && model.lifecycleState == .stopped
                && model.currentOutputUID == output.uid
        }

        #expect(lookup.defaultOutputCalls == 1)
        #expect(engine.startCalls.map(\.output) == [output])
        #expect(model.currentOutputUID == output.uid)
        #expect(model.currentOutputName == output.name)
        #expect(!model.isRunning)
        #expect(model.lifecycleState == .stopped)
    }

    @Test
    func settingsRetryDisabledActiveProfileDoesNotStartEngine() async throws {
        var disabled = makeProfile(name: "Disabled")
        disabled.isBypassed = true
        let output = makeOutput(uid: "retry-disabled-output", name: "Retry Disabled Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let model = makeModel(
            store: ProfileStore(profiles: [disabled], fallbackProfileID: disabled.id),
            engine: engine,
            lookup: lookup
        )

        let response = try await model.performSettingsCommand(.retryAudioEngine)
        await settleAsyncWork()

        let snapshot = try #require(response.snapshot)
        #expect(snapshot.statusMessage == localized("Audio processing disabled"))
        #expect(snapshot.activeProfileID == disabled.id)
        #expect(engine.startCalls.isEmpty)
        #expect(engine.updateCalls.isEmpty)
        #expect(engine.updateDSPCalls.isEmpty)
        #expect(engine.stopCallCount == 0)
        #expect(lookup.defaultOutputCalls == 0)
        #expect(!model.isRunning)
        #expect(model.lifecycleState == .stopped)
    }

    @Test
    func outputChangeClearsPreviewAndStopPreviewIsNoOp() async {
        let fallback = makeProfile(name: "Fallback")
        let preview = makeProfile(name: "Preview")
        let mapped = makeProfile(name: "Mapped")
        let output = makeOutput(uid: "mapped-output", name: "Mapped Output")
        let store = ProfileStore(
            profiles: [fallback, preview, mapped],
            outputMappings: [
                OutputDeviceProfileMapping(outputDeviceUID: output.uid, profileID: mapped.id)
            ],
            fallbackProfileID: fallback.id
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.preview(profile: preview)
        #expect(model.previewReturnProfile?.id == fallback.id)

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.previewReturnProfile == nil
                && model.activeProfile.id == mapped.id
                && model.lifecycleState == .running
        }

        #expect(model.previewReturnProfile == nil)
        #expect(model.activeProfile.id == mapped.id)
        #expect(model.lifecycleState == .running)

        model.stopPreview()

        #expect(model.activeProfile.id == mapped.id)
        #expect(model.previewReturnProfile == nil)
    }

    @Test
    func outputChangeToBypassedProfileDoesNotStartEngine() async {
        let fallback = makeProfile(name: "Fallback")
        var disabled = makeProfile(name: "Disabled")
        disabled.isBypassed = true
        let output = makeOutput(uid: "disabled-output", name: "Disabled Output")
        let store = ProfileStore(
            profiles: [fallback, disabled],
            outputMappings: [
                OutputDeviceProfileMapping(outputDeviceUID: output.uid, profileID: disabled.id)
            ],
            fallbackProfileID: fallback.id
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(store: store, engine: engine, lookup: lookup, observers: observers, outputDelay: .zero)

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.activeProfile.id == disabled.id
                && model.lifecycleState == .stopped
                && model.statusMessage == localized("Audio processing disabled for \(output.name)")
        }

        #expect(engine.startCalls.isEmpty)
        #expect(engine.stopCallCount == 0)
        #expect(!model.isRunning)
        #expect(model.activeProfile.isBypassed)
    }

    @Test
    func startDoesNotBlockOnAsyncObserverStart() async throws {
        let observers = BlockingAsyncDefaultOutputObserverFactory()
        let model = makeModel(observers: observers, outputDelay: .zero)

        let start = Date()
        model.start()
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.05)
        let observer = try #require(observers.observers.first)
        await waitUntil {
            observer.startCalls == [true]
        }
        #expect(model.lifecycleState == .stopped)

        model.stop()
        observer.resumeStart()
        await waitUntil {
            observer.stopCallCount == 1
        }

        #expect(observer.stopCallCount == 1)
    }

    @Test
    func availabilityFailureDuringRouteSwitchStartsSettledDefaultOutput() async {
        let airPods = makeOutput(
            uid: "airpods-output",
            name: "AirPods",
            id: 100,
            transportType: kAudioDeviceTransportTypeBluetooth
        )
        let speakers = makeOutput(uid: "speaker-output", name: "Mac Speakers", id: 200)
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(airPods))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(airPods))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        lookup.result = .success(speakers)
        observer.emit(.failure(AudioDeviceAvailabilityError.outputDeviceNotAlive(airPods.id)))

        await waitUntil {
            model.lifecycleState == .running
                && engine.startCalls.count == 2
                && model.currentOutputUID == speakers.uid
        }

        #expect(model.isRunning)
        #expect(model.currentOutputName == speakers.name)
        #expect(engine.startCalls.map(\.output) == [airPods, speakers])
        #expect(model.statusMessage == localized("Processing \(speakers.name) with \(model.activeProfile.name)"))
    }

    @Test
    func runningOutputUIDChangeMutesImmediatelyThenRebuildsSettledOutput() async {
        let speakers = makeOutput(uid: "speaker-output", name: "Mac Speakers", id: 200)
        let scarlett = makeOutput(uid: "scarlett-output", name: "Scarlett Solo", id: 300)
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(speakers))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .milliseconds(200)
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(speakers))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        lookup.result = .success(scarlett)
        observer.emit(.success(scarlett))

        await waitUntil {
            engine.muteOutputCallCount == 1
        }
        #expect(engine.muteOutputCallCount == 1)
        #expect(model.statusMessage == localized("Audio output changed; rebuilding..."))
        #expect(engine.startCalls.map(\.output) == [speakers])

        await waitUntil {
            engine.startCalls.map(\.output) == [speakers, scarlett]
        }

        #expect(model.currentOutputUID == scarlett.uid)
        #expect(model.lifecycleState == .running)
        #expect(engine.events == ["start:\(speakers.uid)", "mute", "start:\(scarlett.uid)"])
    }

    @Test
    func runningOutputFormatChangeMutesImmediatelyThenRebuildsSettledOutput() async {
        let initialOutput = makeOutput(
            uid: "same-output",
            name: "USB DAC",
            id: 200,
            nominalSampleRate: 48_000,
            bufferFrameSize: 256
        )
        let changedOutput = makeOutput(
            uid: "same-output",
            name: "USB DAC",
            id: 200,
            nominalSampleRate: 44_100,
            bufferFrameSize: 512
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(initialOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .milliseconds(200)
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(initialOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        lookup.result = .success(changedOutput)
        observer.emit(.success(changedOutput))

        await waitUntil {
            engine.muteOutputCallCount == 1
        }
        #expect(engine.muteOutputCallCount == 1)
        #expect(model.statusMessage == localized("Audio output format changed; rebuilding..."))
        #expect(engine.startCalls.map(\.output) == [initialOutput])

        await waitUntil {
            engine.startCalls.map(\.output) == [initialOutput, changedOutput]
        }

        #expect(model.currentOutputSampleRate == changedOutput.nominalSampleRate)
        #expect(model.currentOutputBufferFrameSize == changedOutput.bufferFrameSize)
    }

    @Test
    func stopThenImmediateRestartEnqueuesStopBeforeNewStart() async {
        let output = makeOutput(uid: "restart-output", name: "Restart Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        model.stop()
        model.start()
        observers.observers.last?.emit(.success(output))

        await waitUntil {
            engine.stopCallCount == 1 && engine.startCalls.count == 2
        }

        #expect(engine.events == ["start:\(output.uid)", "stop", "start:\(output.uid)"])
        #expect(model.lifecycleState == .running)
    }

    @Test
    func staleAsyncStartCompletionDoesNotReplaceNewerRouteSwitch() async {
        let firstOutput = makeOutput(uid: "first-output", name: "First Output", id: 200)
        let secondOutput = makeOutput(uid: "second-output", name: "Second Output", id: 300)
        let engine = FakeAudioEngine()
        engine.blockStart(for: firstOutput.uid)
        let lookup = FakeDefaultOutputLookup(.success(firstOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(firstOutput))
        await waitUntil {
            engine.startCalls.count == 1
        }
        #expect(engine.waitUntilStartIsBlocked(for: firstOutput.uid, timeout: .now() + 1))

        lookup.result = .success(secondOutput)
        observer.emit(.success(secondOutput))
        engine.unblockStart(for: firstOutput.uid)
        await waitUntil {
            model.lifecycleState == .running
                && model.currentOutputUID == secondOutput.uid
                && engine.startCalls.contains { $0.output == secondOutput }
        }

        #expect(model.currentOutputUID == secondOutput.uid)
        #expect(model.currentOutputName == secondOutput.name)
        #expect(model.statusMessage == localized("Processing \(secondOutput.name) with \(model.activeProfile.name)"))
        #expect(engine.stopCallCount == 0)

        try? await Task.sleep(for: .milliseconds(120))
        #expect(engine.state == .running(output: secondOutput))
    }

    @Test
    func userStopDuringSlowStartCleansUpAfterCancelledStartFinishes() async {
        let output = makeOutput(uid: "slow-start-output", name: "Slow Start Output", id: 200)
        let engine = FakeAudioEngine()
        engine.blockStart(for: output.uid)
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            engine.startCalls.count == 1
        }
        #expect(engine.waitUntilStartIsBlocked(for: output.uid, timeout: .now() + 1))

        model.stop()
        engine.unblockStart(for: output.uid)

        await waitUntil {
            engine.stopCallCount == 2
        }

        #expect(engine.stopCallCount == 2)
        #expect(engine.state == .stopped)
        #expect(!model.isRunning)
        #expect(model.lifecycleState == .stopped)
    }

    @Test
    func staleObserverCallbackAfterStopAndRestartIsIgnored() async {
        let staleOutput = makeOutput(uid: "stale-output", name: "Stale Output")
        let liveOutput = makeOutput(uid: "live-output", name: "Live Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(liveOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let firstObserver = observers.observers[0]
        model.stop()
        model.start()
        let secondObserver = observers.observers[1]

        firstObserver.emit(.success(staleOutput))
        await settleAsyncWork()

        #expect(engine.startCalls.isEmpty)
        #expect(lookup.defaultOutputCalls == 0)

        secondObserver.emit(.success(liveOutput))
        await waitUntil {
            engine.startCalls.map(\.output) == [liveOutput]
                && model.currentOutputUID == liveOutput.uid
                && model.lifecycleState == .running
        }

        #expect(engine.startCalls.map(\.output) == [liveOutput])
        #expect(model.currentOutputUID == liveOutput.uid)
        #expect(model.lifecycleState == .running)
    }

    @Test
    func pendingDebounceIsCancelledByStop() async {
        let output = makeOutput(uid: "delayed-output", name: "Delayed Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .milliseconds(80)
        )

        model.start()
        observers.observers[0].emit(.success(output))
        model.stop()
        try? await Task.sleep(for: .milliseconds(120))

        #expect(engine.startCalls.isEmpty)
        #expect(lookup.defaultOutputCalls == 0)
        #expect(model.lifecycleState == .stopped)
    }

    @Test
    func sleepClearsPreviewAndWakeCreatesFreshObserverGeneration() async {
        let output = makeOutput(uid: "wake-output", name: "Wake Output")
        let fallback = makeProfile(name: "Fallback")
        let preview = makeProfile(name: "Preview")
        let store = ProfileStore(profiles: [fallback, preview], fallbackProfileID: fallback.id)
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.retryAudioEngine()
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        model.preview(profile: preview)
        model.start()
        let preSleepObserver = observers.observers[0]

        model.handleWillSleep()
        #expect(model.previewReturnProfile == nil)
        #expect(model.lifecycleState == .sleeping)

        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 2
        }
        #expect(model.lifecycleState == .waking)
        #expect(observers.observers.count == 2)

        preSleepObserver.emit(.success(output))
        await settleAsyncWork()
        #expect(engine.startCalls.count == 1)

        observers.observers[1].emit(.success(output))
        await waitUntil {
            engine.startCalls.count == 2 && model.lifecycleState == .running
        }
        #expect(engine.startCalls.count == 2)
        #expect(model.lifecycleState == .running)
    }

    @Test
    func wakeReconnectRetriesAfterTransientOutputFailure() async {
        let output = makeOutput(uid: "wake-retry-output", name: "Wake Retry Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.retryAudioEngine()
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        model.start()
        model.handleWillSleep()
        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 2 && observers.observers[1].startCalls.count == 1
        }

        let wakeObserver = observers.observers[1]
        lookup.result = .failure(TestAudioError.defaultOutputUnavailable)
        wakeObserver.emit(.failure(TestAudioError.defaultOutputUnavailable))
        await waitUntil {
            wakeObserver.startCalls.count == 2 && model.lifecycleState == .waking
        }
        lookup.result = .success(output)
        wakeObserver.emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 2
        }

        #expect(model.lifecycleState == .running)
        #expect(model.isRunning)
        #expect(engine.startCalls.map(\.output) == [output, output])
    }

    @Test
    func sessionActivationRecoversSleepingStateWhenDidWakeIsMissed() async {
        let output = makeOutput(uid: "missed-wake-output", name: "Missed Wake Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        model.handleWillSleep()
        #expect(model.lifecycleState == .sleeping)

        model.handleSessionDidBecomeActive()
        await waitUntil {
            observers.observers.count == 2 && observers.observers[1].startCalls == [true]
        }

        observers.observers[1].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 2
        }

        #expect(model.isRunning)
        #expect(model.statusMessage == localized("Processing \(output.name) with \(model.activeProfile.name)"))
    }

    @Test
    func sessionActivationDuringPendingSleepReconnectDoesNotResetRetryBudget() async {
        let output = makeOutput(uid: "late-session-wake-output", name: "Late Session Wake Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        model.handleWillSleep()
        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 2 && observers.observers[1].startCalls == [true]
        }

        model.handleSessionDidBecomeActive()
        await settleAsyncWork()
        #expect(observers.observers[1].startCalls == [true])

        observers.observers[1].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 2
        }

        #expect(model.isRunning)
        #expect(model.statusMessage == localized("Processing \(output.name) with \(model.activeProfile.name)"))
    }

    @Test
    func repeatedSleepWakeCyclesCreateFreshObserversAndReconnect() async {
        let output = makeOutput(uid: "repeated-wake-output", name: "Repeated Wake Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        model.handleWillSleep()
        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 2 && observers.observers[1].startCalls == [true]
        }
        observers.observers[1].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 2
        }

        model.handleWillSleep()
        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 3 && observers.observers[2].startCalls == [true]
        }
        observers.observers[1].emit(.success(output))
        await settleAsyncWork()
        #expect(engine.startCalls.count == 2)

        observers.observers[2].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 3
        }

        #expect(observers.observers[0].stopCallCount == 1)
        #expect(observers.observers[1].stopCallCount == 1)
        #expect(model.isRunning)
        #expect(model.statusMessage == localized("Processing \(output.name) with \(model.activeProfile.name)"))
    }

    @Test
    func sleepDuringPendingWakeReconnectPreservesResumeIntent() async {
        let output = makeOutput(uid: "nested-sleep-output", name: "Nested Sleep Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        model.handleWillSleep()
        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 2 && observers.observers[1].startCalls == [true]
        }

        model.handleWillSleep()
        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 3 && observers.observers[2].startCalls == [true]
        }

        observers.observers[2].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 2
        }

        #expect(model.isRunning)
        #expect(model.statusMessage == localized("Processing \(output.name) with \(model.activeProfile.name)"))
    }

    @Test
    func wakeAfterStoppedSleepClearsPausedStatus() {
        let model = makeModel()

        model.handleWillSleep()
        #expect(model.lifecycleState == .sleeping)
        #expect(model.statusMessage == localized("Paused for system sleep"))

        model.handleDidWake()

        #expect(model.lifecycleState == .stopped)
        #expect(!model.isRunning)
        #expect(model.statusMessage == localized("Stopped"))
    }

    @Test
    func sessionActivationDoesNotRebuildRunningOutputWithoutSleepIntent() async {
        let output = makeOutput(uid: "unlock-output", name: "Unlock Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        let lookupCallsBeforeActivation = lookup.defaultOutputCalls

        model.handleSessionDidBecomeActive()
        await settleAsyncWork()

        #expect(engine.muteOutputCallCount == 0)
        #expect(model.lifecycleState == .running)
        #expect(observer.startCalls == [true])
        #expect(observers.observers.count == 1)
        #expect(engine.startCalls.map(\.output) == [output])
        #expect(lookup.defaultOutputCalls == lookupCallsBeforeActivation)
        #expect(model.isRunning)
    }

    @Test
    func wakingProfileActionsUpdateStateWithoutDirectEngineMutation() async throws {
        let output = makeOutput(uid: "waking-profile-output", name: "Waking Profile Output")
        let fallback = makeProfile(name: "Fallback")
        let applied = makeProfile(name: "Applied During Wake")
        let mapped = makeProfile(name: "Mapped During Wake")
        let store = ProfileStore(
            profiles: [fallback, applied, mapped],
            fallbackProfileID: fallback.id
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        engine.blockStart(for: output.uid)
        model.handleWillSleep()
        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 2 && observers.observers[1].startCalls == [true]
        }
        observers.observers[1].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .waking && engine.startCalls.count == 2
        }
        #expect(engine.waitUntilStartIsBlocked(for: output.uid, timeout: .now() + 1))

        try model.apply(profile: applied)
        try model.useForCurrentOutput(profile: mapped)
        model.setBypass(true)

        #expect(model.lifecycleState == .stopped)
        #expect(model.activeProfile.id == mapped.id)
        #expect(model.activeProfile.isBypassed)
        #expect(model.previewReturnProfile == nil)
        #expect(engine.updateCalls.isEmpty)
        #expect(engine.updateDSPCalls.isEmpty)
        #expect(engine.setBypassedCalls.isEmpty)
        #expect(model.profileStore.profile(forOutputUID: output.uid).id == mapped.id)

        engine.unblockStart(for: output.uid)
        await waitUntil {
            engine.stopCallCount == 1
        }

        #expect(!model.isRunning)
        #expect(model.lifecycleState == .stopped)
        #expect(model.statusMessage == localized("Audio processing disabled for \(output.name)"))
    }

    @Test
    func userStoppedEngineBeforeSleepDoesNotReconnectOnWake() async {
        let output = makeOutput(uid: "stopped-before-sleep-output", name: "Stopped Before Sleep Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        model.stop()
        model.handleWillSleep()
        model.handleDidWake()
        await settleAsyncWork()

        #expect(engine.startCalls.map(\.output) == [output])
        #expect(observers.observers.count == 1)
        #expect(observer.stopCallCount == 1)
        #expect(!model.isRunning)
        #expect(model.lifecycleState == .stopped)
        #expect(model.statusMessage == localized("Stopped"))
    }

    @Test
    func cleanupForTerminationIsTerminal() async {
        let output = makeOutput(uid: "terminal-output", name: "Terminal Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        model.cleanupForTermination()
        model.start()
        model.retryAudioEngine()
        observer.emit(.success(output))
        await settleAsyncWork()

        #expect(model.lifecycleState == .terminating)
        #expect(!model.isRunning)
        #expect(engine.startCalls.isEmpty)
        #expect(lookup.defaultOutputCalls == 0)
    }

    @Test
    func settingsCreateProfileCommandReturnsUpdatedSnapshot() async throws {
        let model = makeModel()
        let initialCount = model.profileStore.profiles.count

        let response = try await model.performSettingsCommand(.createProfile(.parametric))

        let snapshot = try #require(response.snapshot)
        #expect(snapshot.profiles.count == initialCount + 1)
        #expect(snapshot.draftProfile.mode == .parametric)
        #expect(snapshot.selectedProfileID == snapshot.draftProfile.id)
    }

    @Test
    func settingsApplyProfileCommandRejectsInvalidProfile() async throws {
        let model = makeModel()
        var invalid = model.activeProfile
        invalid.name = "   "

        await #expect(throws: ProfileStoreValidationError.self) {
            _ = try await model.performSettingsCommand(.applyProfile(invalid))
        }
    }

    @Test
    func settingsApplyProfileRejectsDisabledFilterOverloadWithoutMutation() async throws {
        let model = makeModel()
        let initialStore = model.profileStore
        let initialActiveProfile = model.activeProfile
        var overloaded = model.activeProfile
        overloaded.filters = (0...ProfilePersistence.maxFiltersPerChannel).map {
            EQFilter(kind: .peak, frequency: Double($0 + 1), gainDB: 0, q: 1, isEnabled: false)
        }

        await #expect(throws: ProfileStoreValidationError.tooManyFilters(
            profileID: overloaded.id,
            channel: "linked",
            count: ProfilePersistence.maxFiltersPerChannel + 1,
            maximum: ProfilePersistence.maxFiltersPerChannel
        )) {
            _ = try await model.performSettingsCommand(.applyProfile(overloaded))
        }

        #expect(model.profileStore == initialStore)
        #expect(model.activeProfile == initialActiveProfile)
    }

    @Test
    func settingsCreateProfileAtLimitThrowsWithoutMutation() async throws {
        let store = makeStore(profileCount: ProfilePersistence.profileCountRange.upperBound)
        let model = makeModel(store: store)
        let initialSelection = model.selectedProfileID

        await #expect(throws: ProfileStoreValidationError.invalidProfileCount(
            count: ProfilePersistence.profileCountRange.upperBound + 1,
            allowed: ProfilePersistence.profileCountRange
        )) {
            _ = try await model.performSettingsCommand(.createProfile(.parametric))
        }

        #expect(model.profileStore == store)
        #expect(model.selectedProfileID == initialSelection)
    }

    @Test
    func settingsDuplicateUsesExplicitProfileID() async throws {
        let first = makeProfile(name: "First")
        let second = makeProfile(name: "Second")
        let store = ProfileStore(profiles: [first, second], fallbackProfileID: first.id)
        let model = makeModel(store: store)
        model.selectProfile(first.id)

        let response = try await model.performSettingsCommand(.duplicateProfile(second.id))

        let snapshot = try #require(response.snapshot)
        #expect(snapshot.profiles.count == 3)
        #expect(snapshot.draftProfile.name == "Second Copy")
        #expect(snapshot.draftProfile.id != second.id)
        #expect(snapshot.selectedProfileID == snapshot.draftProfile.id)
    }

    @Test
    func settingsDuplicateStaleIDThrowsWithoutDuplicatingSelectedProfile() async throws {
        let model = makeModel()
        let initialStore = model.profileStore

        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await model.performSettingsCommand(.duplicateProfile(UUID()))
        }

        #expect(model.profileStore == initialStore)
    }

    @Test
    func bypassAfterSelectingDifferentDraftOnlyTogglesActiveProfileAndStopsEngine() async {
        let active = makeProfile(name: "Active")
        let draft = makeProfile(name: "Draft")
        let output = makeOutput(uid: "bypass-output", name: "Bypass Output")
        let store = ProfileStore(profiles: [active, draft], fallbackProfileID: active.id)
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(store: store, engine: engine, observers: observers, outputDelay: .zero)

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        model.selectProfile(draft.id)

        model.setBypass(true)
        await waitUntil {
            engine.stopCallCount == 1
        }

        #expect(model.activeProfile.id == active.id)
        #expect(model.activeProfile.isBypassed)
        #expect(model.selectedProfileID == draft.id)
        #expect(model.draftProfile.id == draft.id)
        #expect(!model.draftProfile.isBypassed)
        #expect(model.profileStore.profiles.first { $0.id == active.id }?.isBypassed == true)
        #expect(model.profileStore.profiles.first { $0.id == draft.id }?.isBypassed == false)
        #expect(engine.updateDSPCalls.isEmpty)
        #expect(engine.setBypassedCalls.isEmpty)
        #expect(engine.stopCallCount == 1)
        #expect(!model.isRunning)
        #expect(model.lifecycleState == .stopped)
    }

    @Test
    func bypassMirrorsDraftWhenSelectedProfileIsActiveProfileAndStopsEngine() async {
        let active = makeProfile(name: "Active")
        let output = makeOutput(uid: "active-bypass-output", name: "Active Bypass Output")
        let store = ProfileStore(profiles: [active], fallbackProfileID: active.id)
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(store: store, engine: engine, observers: observers, outputDelay: .zero)

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        model.setBypass(true)
        await waitUntil {
            engine.stopCallCount == 1
        }

        #expect(model.activeProfile.id == active.id)
        #expect(model.activeProfile.isBypassed)
        #expect(model.draftProfile.id == active.id)
        #expect(model.draftProfile.isBypassed)
        #expect(model.profileStore.profiles.first { $0.id == active.id }?.isBypassed == true)
        #expect(engine.updateDSPCalls.isEmpty)
        #expect(engine.setBypassedCalls.isEmpty)
        #expect(engine.stopCallCount == 1)
        #expect(!model.isRunning)
        #expect(model.lifecycleState == .stopped)
    }

    @Test
    func unsupportedSchemaStoreIsProtectedUntilExplicitReset() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let futureProfile = makeProfile(name: "Future Profile")
        let futureStore = ProfileStore(
            schemaVersion: ProfileStore.currentSchemaVersion + 1,
            profiles: [futureProfile],
            fallbackProfileID: futureProfile.id
        )
        let futureData = try ProfilePersistence.encoder.encode(futureStore)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try futureData.write(to: storeURL)

        let model = GlassEQAppModel(
            storeURL: storeURL,
            engine: FakeAudioEngine(),
            defaultOutputLookup: FakeDefaultOutputLookup(.success(makeOutput())),
            observerFactory: FakeDefaultOutputObserverFactory(),
            autoStart: false,
            installLifecycleObservers: false,
            registerAppDelegate: false
        )

        #expect(model.settingsSnapshot().profileStoreProtection.isProtected)
        #expect(model.profileStore.profiles == ProfileStore.defaultProfiles)
        #expect(await model.flushStoreBeforeQuit())
        #expect(try Data(contentsOf: storeURL) == futureData)

        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await model.performSettingsCommand(.createProfile(.parametric))
        }
        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await model.performSettingsCommand(.applyProfile(model.activeProfile))
        }
        #expect(try Data(contentsOf: storeURL) == futureData)

        let response = try await model.performSettingsCommand(.resetUnsupportedProfileStore)
        let snapshot = try #require(response.snapshot)
        #expect(!snapshot.profileStoreProtection.isProtected)
        #expect(try ProfilePersistence.decode(Data(contentsOf: storeURL)).profiles == ProfileStore.defaultProfiles)

        let backups = try FileManager.default.contentsOfDirectory(
            at: storeURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
            .filter { $0.lastPathComponent.hasPrefix("Profiles.invalid-") }
        #expect(backups.count == 1)
        if let backup = backups.first {
            #expect(try Data(contentsOf: backup) == futureData)
        }

        _ = try await model.performSettingsCommand(.createProfile(.parametric))
        #expect(model.profileStore.profiles.count == ProfileStore.defaultProfiles.count + 1)
    }

    @Test
    func preservedRunningProfileUpdateFailureRevertsModelToRunningProfile() async throws {
        let running = makeProfile(name: "Running")
        let requested = makeProfile(name: "Requested")
        let output = makeOutput(uid: "preserved-output", name: "Preserved Output")
        let store = ProfileStore(profiles: [running, requested], fallbackProfileID: running.id)
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        engine.updateDSPResult = false
        engine.updateError = TestAudioError.updateFailed
        engine.updateErrorPreservesRunningState = true

        try model.apply(profile: requested)

        await waitUntil {
            engine.updateCalls.count == 1 && model.statusMessage.contains("not applied")
        }

        #expect(model.lifecycleState == .running)
        #expect(model.isRunning)
        #expect(model.currentOutputUID == output.uid)
        #expect(model.activeProfile == running)
        #expect(model.selectedProfileID == running.id)
        #expect(model.draftProfile == running)
        #expect(model.profileStore == store)
        #expect(engine.state == .running(output: output))
    }

    @Test
    func settingsDeleteStaleAndActiveIDsThrowWithoutMutation() async throws {
        let inactive = makeProfile(name: "Inactive")
        let store = ProfileStore(profiles: [makeProfile(name: "Active"), inactive])
        let model = makeModel(store: store)
        let initialStore = model.profileStore

        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await model.performSettingsCommand(.deleteProfile(UUID()))
        }
        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await model.performSettingsCommand(.deleteProfile(model.activeProfile.id))
        }

        #expect(model.profileStore == initialStore)
    }

    @Test
    func settingsImportAtProfileLimitThrowsWithoutAppending() async throws {
        let store = makeStore(profileCount: ProfilePersistence.profileCountRange.upperBound)
        let model = makeModel(store: store)
        let text = "Filter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1"

        await #expect(throws: ProfileStoreValidationError.invalidProfileCount(
            count: ProfilePersistence.profileCountRange.upperBound + 1,
            allowed: ProfilePersistence.profileCountRange
        )) {
            _ = try await model.performSettingsCommand(.importProfile(format: .autoEQ, name: "Imported", text: text))
        }

        #expect(model.profileStore == store)
    }

    @Test
    func metricsPollingCommandReturnsNoSnapshotAndPublishesImmediateMetrics() async throws {
        let engine = FakeAudioEngine()
        engine.metrics = AudioEngineMetrics(
            capturedFrames: 123,
            playedFrames: 100,
            ringGateContentionFailures: 2
        )
        let model = makeModel(engine: engine)

        let response = try await model.performSettingsCommand(.startMetricsPolling)

        #expect(response.snapshot == nil)
        #expect(model.engineMetrics.capturedFrames == 123)
        #expect(model.engineMetrics.playedFrames == 100)
        #expect(model.engineMetrics.ringGateContentionFailures == 2)
        model.stopMetricsPolling()
    }

    @Test
    func openPrivacySettingsReportsFailureWhenSystemSettingsCannotOpen() async throws {
        let opener = FakeWorkspaceOpener(results: [false, false])
        let model = makeModel(workspaceOpener: opener)

        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await model.performSettingsCommand(.openPrivacySettings)
        }

        #expect(opener.openedURLs.count == 2)
    }

    @Test
    func openPrivacySettingsAllowsFallbackURLSuccess() async throws {
        let opener = FakeWorkspaceOpener(results: [false, true])
        let model = makeModel(workspaceOpener: opener)

        _ = try await model.performSettingsCommand(.openPrivacySettings)

        #expect(opener.openedURLs.count == 2)
    }

    @Test
    func debouncedProfileSavesCoalesceAndFlushPersistsLatestState() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQAppTests-\(UUID().uuidString).json")
        let model = makeModel(storeURL: storeURL, saveDelay: .milliseconds(100))

        try model.createProfile(kind: .parametric)
        try model.createProfile(kind: .graphic10)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
        #expect(await model.flushStoreBeforeQuit())

        let loaded = ProfilePersistence.load(from: storeURL).store
        #expect(loaded.profiles.count == 3)
        #expect(loaded.profiles.contains { $0.name == "New Parametric" })
        #expect(loaded.profiles.contains { $0.name == "New 10-Band" })
    }

    @Test
    func quitWaitsForInFlightImportBeforeFlushingProfiles() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let importer = BlockingProfileImportOperation()
        let importedProfile = makeProfile(name: "Imported Before Quit")
        let model = makeModel(
            storeURL: storeURL,
            profileImportOperation: { format, name, text in
                await importer.run(format: format, name: name, text: text)
            }
        )

        let importTask = Task {
            try await model.performSettingsCommand(.importProfile(
                format: .autoEQ,
                name: importedProfile.name,
                text: "1 0"
            ))
        }
        await waitUntil {
            importer.hasEntered
        }

        let flushTask = Task {
            await model.stopAcceptingSettingsCommandsAndWait()
            return await model.flushStoreBeforeQuit()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))

        importer.complete(with: .success(importedProfile))
        _ = try await importTask.value
        #expect(await flushTask.value)

        let loaded = ProfilePersistence.load(from: storeURL).store
        #expect(loaded.profiles.contains { $0.name == importedProfile.name })
        model.resumeSettingsCommandsAfterCancelledQuit()
    }

    @Test
    func settingsLaunchValidationFailureTerminatesPartiallyStartedHelper() async throws {
        let model = makeModel()
        let launcher = SleepingSettingsHelperLauncher()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: launcher,
            helperValidator: FailingSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        let disposition = coordinator.openSettings()

        let process = try #require(launcher.launchedProcesses.first)
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        #expect(!coordinator.hasActiveSessionResourcesForTesting)
        if case .inProcessFallback(let reason) = disposition {
            #expect(reason.contains("Intentional post-launch validation failure"))
        } else {
            Issue.record("Expected in-process Settings fallback")
        }
        for _ in 0..<250 {
            if !process.isRunning {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!process.isRunning)
    }

    @Test
    func settingsLaunchPermissionFailureRequestsInProcessFallback() {
        let model = makeModel()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: PermissionDeniedSettingsHelperLauncher(),
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        let disposition = coordinator.openSettings()

        #expect(!coordinator.hasActiveSessionResourcesForTesting)
        if case .inProcessFallback(let reason) = disposition {
            #expect(reason.contains("Operation not permitted"))
        } else {
            Issue.record("Expected in-process Settings fallback after EPERM")
        }
    }

    @Test
    func settingsHelperExitBeforeConnectingRequestsInProcessFallback() async throws {
        let model = makeModel()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: ProcessSettingsHelperLauncher(),
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        #expect(coordinator.openSettings() == .helper)

        for _ in 0..<100 where model.inProcessSettingsPresentationGeneration == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.inProcessSettingsPresentationGeneration == 1)
        #expect(model.statusMessage.contains("exited before connecting"))
        #expect(!coordinator.hasActiveSessionResourcesForTesting)
    }

    @Test
    func settingsHelperExitAfterConnectBeforeReadyRequestsInProcessFallback() async throws {
        let model = makeModel()
        let launcher = ControllableSettingsHelperLauncher()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: launcher,
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        #expect(coordinator.openSettings() == .helper)
        let bootstrap = try #require(launcher.readHostMessages().first)
        guard case .bootstrap(let token) = bootstrap else {
            Issue.record("Expected Settings bootstrap message")
            return
        }
        try launcher.writeHelperOutput(try SettingsPipeCodec.encodeLine(
            .request(sessionToken: token, id: "connect", kind: .connect, command: nil)
        ))
        try launcher.closeHelperOutput()

        for _ in 0..<100 where model.inProcessSettingsPresentationGeneration == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.inProcessSettingsPresentationGeneration == 1)
        #expect(model.statusMessage.contains("exited before connecting"))
        #expect(!coordinator.hasActiveSessionResourcesForTesting)
    }

    @Test
    func malformedSettingsIPCBeforeConnectingRequestsInProcessFallback() async throws {
        let model = makeModel()
        let launcher = ControllableSettingsHelperLauncher()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: launcher,
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        #expect(coordinator.openSettings() == .helper)
        try launcher.writeHelperOutput(Data("not-json\n".utf8))

        for _ in 0..<100 where model.inProcessSettingsPresentationGeneration == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.inProcessSettingsPresentationGeneration == 1)
        #expect(model.statusMessage.contains("IPC failed before connecting"))
        #expect(!coordinator.hasActiveSessionResourcesForTesting)
    }

    @Test
    func settingsModelNotificationPublishesMetricsOnlyChanges() async throws {
        let model = makeModel()
        let launcher = ControllableSettingsHelperLauncher()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: launcher,
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        #expect(coordinator.openSettings() == .helper)
        let bootstrap = try #require(launcher.readHostMessages().first)
        guard case .bootstrap(let token) = bootstrap else {
            Issue.record("Expected Settings bootstrap message")
            return
        }
        let requests = try SettingsPipeCodec.encodeLine(
            .request(sessionToken: token, id: "connect", kind: .connect, command: nil)
        ) + SettingsPipeCodec.encodeLine(
            .request(sessionToken: token, id: "ready", kind: .ready, command: nil)
        )
        try launcher.writeHelperOutput(requests)
        for _ in 0..<100 where !coordinator.isHelperReadyForTesting {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.isHelperReadyForTesting)
        _ = try launcher.readHostMessages()

        model.engineMetrics = AudioEngineMetrics(capturedFrames: 42)
        coordinator.modelDidChange()

        let expectedMessage = SettingsPipeMessage.event(
            sessionToken: token,
            event: .metricsChanged(SettingsAudioMetricsDTO(capturedFrames: 42))
        )
        var messages: [SettingsPipeMessage] = []
        for _ in 0..<100 where !messages.contains(expectedMessage) {
            try await Task.sleep(for: .milliseconds(10))
            messages.append(contentsOf: try launcher.readHostMessages())
        }
        #expect(messages.contains(expectedMessage))
        coordinator.shutdown()
    }

    @Test
    func settingsReadyPublishesChangesThatOccurredAfterConnect() async throws {
        let model = makeModel()
        let launcher = ControllableSettingsHelperLauncher()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: launcher,
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        #expect(coordinator.openSettings() == .helper)
        await waitUntil {
            launcher.receivedAppMessages.contains { message in
                if case .bootstrap = message {
                    return true
                }
                return false
            }
        }
        let bootstrap = try #require(launcher.receivedAppMessages.first)
        guard case .bootstrap(let token) = bootstrap else {
            Issue.record("Expected Settings bootstrap message")
            return
        }
        try launcher.writeHelperMessage(.request(
            sessionToken: token,
            id: "connect",
            kind: .connect,
            command: nil
        ))
        await waitUntil {
            launcher.receivedAppMessages.contains { message in
                if case .response(_, "connect", _, _) = message {
                    return true
                }
                return false
            }
        }

        model.statusMessage = "Changed before ready"
        model.engineMetrics = AudioEngineMetrics(capturedFrames: 42)
        coordinator.modelDidChange()
        coordinator.metricsDidChange()
        try launcher.writeHelperMessage(.request(
            sessionToken: token,
            id: "ready",
            kind: .ready,
            command: nil
        ))

        await waitUntil {
            launcher.receivedAppMessages.contains { message in
                guard case .event(_, .snapshotChanged(let snapshot)) = message else {
                    return false
                }
                return snapshot.statusMessage == "Changed before ready"
                    && snapshot.metrics.capturedFrames == 42
            }
        }
        #expect(coordinator.isHelperReadyForTesting)
        coordinator.shutdown()
    }

    @Test
    func settingsBootstrapWriteFailureRequestsInProcessFallback() async throws {
        let model = makeModel()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: try ClosedInputSettingsHelperLauncher(),
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        #expect(coordinator.openSettings() == .helper)

        for _ in 0..<100 where model.inProcessSettingsPresentationGeneration == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.inProcessSettingsPresentationGeneration == 1)
        #expect(model.statusMessage.contains("IPC failed before connecting"))
        #expect(!coordinator.hasActiveSessionResourcesForTesting)
    }

    @Test
    func activeInProcessSettingsFallbackIsReusedWithoutLaunchingHelper() {
        let model = makeModel()

        model.inProcessSettingsDidAppear()
        #expect(model.openSettings() == .activeInProcessFallback)

        model.inProcessSettingsDidDisappear()
    }

    @Test
    func pendingInProcessSettingsFallbackIsReusedWithoutLaunchingHelper() {
        let model = makeModel()

        model.requestInProcessSettingsPresentation()
        let firstGeneration = model.inProcessSettingsPresentationGeneration

        #expect(model.openSettings() == .activeInProcessFallback)
        #expect(model.inProcessSettingsPresentationGeneration == firstGeneration + 1)
    }

    @Test
    func inProcessSettingsFallbackPerformsCommandsAndTracksModelChanges() async throws {
        let model = makeModel()
        let settingsModel = model.inProcessSettingsViewModel()
        let snapshotVersion = settingsModel.snapshotVersion

        #expect(settingsModel.isConnected)
        #expect(settingsModel.snapshot == model.settingsSnapshot())
        #expect(model.inProcessSettingsViewModel() === settingsModel)
        #expect(settingsModel.snapshotVersion == snapshotVersion)

        let response = await settingsModel.perform(.createProfile(.parametric))
        #expect(response?.snapshot?.profiles.count == 2)
        #expect(settingsModel.snapshot == model.settingsSnapshot())
    }

    @Test
    func settingsHelperValidationChecksContainmentBundleIDAndSigningPolicy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQHelperValidation-\(UUID().uuidString)", isDirectory: true)
        let hostURL = root.appendingPathComponent("GlassEQ.app", isDirectory: true)
        let helperURL = hostURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        try makeFakeAppBundle(
            at: helperURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        let validator = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID")
        ])

        let executableURL = try SettingsHelperVerifier.validatedExecutableURL(
            for: helperURL,
            hostBundleURL: hostURL,
            codeSigningValidator: validator
        )

        #expect(executableURL.lastPathComponent == "GlassEQSettings")

        let wrongBundleURL = hostURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("WrongSettings.app", isDirectory: true)
        try makeFakeAppBundle(at: wrongBundleURL, bundleIdentifier: "com.example.wrong", executableName: "GlassEQSettings")
        #expect(throws: SettingsCommandFailure.self) {
            _ = try SettingsHelperVerifier.validatedExecutableURL(
                for: wrongBundleURL,
                hostBundleURL: hostURL,
                codeSigningValidator: validator
            )
        }

        let outsideURL = root
            .appendingPathComponent("Outside", isDirectory: true)
            .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        try makeFakeAppBundle(
            at: outsideURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        #expect(throws: SettingsCommandFailure.self) {
            _ = try SettingsHelperVerifier.validatedExecutableURL(
                for: outsideURL,
                hostBundleURL: hostURL,
                codeSigningValidator: validator
            )
        }

        let mismatchedTeam = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "OTHERTEAM")
        ])
        #expect(throws: SettingsCommandFailure.self) {
            _ = try SettingsHelperVerifier.validatedExecutableURL(
                for: helperURL,
                hostBundleURL: hostURL,
                codeSigningValidator: mismatchedTeam
            )
        }

        let adHoc = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: nil),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: nil)
        ])
        _ = try SettingsHelperVerifier.validatedExecutableURL(
            for: helperURL,
            hostBundleURL: hostURL,
            codeSigningValidator: adHoc
        )
    }

    @Test
    func settingsHelperRunningValidationFallsBackWhenLaunchServicesHasNoBundleURL() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQHelperRunningValidation-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let hostURL = root.appendingPathComponent("GlassEQ.app", isDirectory: true)
        let helperURL = hostURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        try makeFakeAppBundle(
            at: helperURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        let validator = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID"),
            "pid:123": SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID")
        ])

        try SettingsHelperVerifier.validateRunningProcess(
            processIdentifier: 123,
            expectedHelperURL: helperURL,
            hostBundleURL: hostURL,
            runningBundleURL: { _ in nil },
            processExecutableURL: { _ in helperExecutableURL(for: helperURL) },
            codeSigningValidator: validator
        )
    }

    @Test
    func settingsHelperRunningValidationRejectsUnexpectedResolvedBundleURL() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQHelperRunningValidation-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let hostURL = root.appendingPathComponent("GlassEQ.app", isDirectory: true)
        let helperURL = hostURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        let otherURL = root.appendingPathComponent("OtherSettings.app", isDirectory: true)
        try makeFakeAppBundle(
            at: helperURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        try makeFakeAppBundle(
            at: otherURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        let validator = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID"),
            otherURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID"),
            "pid:123": SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID")
        ])

        #expect(throws: SettingsCommandFailure.self) {
            try SettingsHelperVerifier.validateRunningProcess(
                processIdentifier: 123,
                expectedHelperURL: helperURL,
                hostBundleURL: hostURL,
                runningBundleURL: { _ in otherURL },
                processExecutableURL: { _ in helperExecutableURL(for: otherURL) },
                codeSigningValidator: validator
            )
        }
    }
}

@MainActor
private func makeModel(
    store: ProfileStore? = nil,
    storeURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("GlassEQAppTests-\(UUID().uuidString).json"),
    engine: FakeAudioEngine = FakeAudioEngine(),
    lookup: FakeDefaultOutputLookup = FakeDefaultOutputLookup(.success(makeOutput())),
    observers: any DefaultOutputObservingMaking = FakeDefaultOutputObserverFactory(),
    workspaceOpener: any WorkspaceOpening = FakeWorkspaceOpener(results: []),
    profileImportOperation: (@Sendable (ImportFormat, String, String) async -> Result<EQProfile, any Error>)? = nil,
    saveDelay: Duration = .zero,
    outputDelay: Duration? = nil,
    wakeDelay: Duration? = nil
) -> GlassEQAppModel {
    let store = normalizedStore(store ?? ProfileStore(profiles: [makeProfile(name: "Fallback")]))
    return GlassEQAppModel(
        profileStore: store,
        storeURL: storeURL,
        engine: engine,
        defaultOutputLookup: lookup,
        observerFactory: observers,
        autoStart: false,
        installLifecycleObservers: false,
        registerAppDelegate: false,
        workspaceOpener: workspaceOpener,
        profileImportOperation: profileImportOperation,
        saveDebounceDelay: saveDelay,
        outputChangeSettlingDelayOverride: outputDelay,
        wakeReconnectDelayOverride: wakeDelay
    )
}

private final class BlockingProfileImportOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var continuation: CheckedContinuation<Result<EQProfile, any Error>, Never>?

    var hasEntered: Bool {
        lock.withLock { entered }
    }

    func run(
        format: ImportFormat,
        name: String,
        text: String
    ) async -> Result<EQProfile, any Error> {
        await withCheckedContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                entered = true
            }
        }
    }

    func complete(with result: Result<EQProfile, any Error>) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}

private func normalizedStore(_ store: ProfileStore) -> ProfileStore {
    guard store.profiles.contains(where: { $0.id == store.fallbackProfileID }) else {
        return ProfileStore(profiles: store.profiles)
    }
    return store
}

private func makeProfile(name: String) -> EQProfile {
    EQProfile(name: name, mode: .parametric, filters: [])
}

private func makeStore(profileCount: Int) -> ProfileStore {
    let profiles = (0..<profileCount).map { index in
        makeProfile(name: "Profile \(index)")
    }
    return ProfileStore(profiles: profiles, fallbackProfileID: profiles[0].id)
}

private func makeOutput(
    uid: String = "output",
    name: String = "Output",
    id: AudioObjectID = 100,
    nominalSampleRate: Double = 48_000,
    bufferFrameSize: UInt32 = 256,
    transportType: UInt32? = nil
) -> AudioOutputDevice {
    AudioOutputDevice(
        id: id,
        uid: uid,
        name: name,
        nominalSampleRate: nominalSampleRate,
        outputChannelCount: 2,
        bufferFrameSize: bufferFrameSize,
        transportType: transportType
    )
}

private func temporaryAppStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("GlassEQAppTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("Profiles.json")
}

private func removeTemporaryStoreDirectory(for url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

private func makeFakeAppBundle(
    at appURL: URL,
    bundleIdentifier: String,
    executableName: String
) throws {
    let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    let info: NSDictionary = [
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundleExecutable": executableName,
        "CFBundlePackageType": "APPL"
    ]
    let plistURL = contentsURL.appendingPathComponent("Info.plist")
    guard info.write(to: plistURL, atomically: true) else {
        Issue.record("Failed to write fake app Info.plist")
        return
    }
    let executableURL = macOSURL.appendingPathComponent(executableName, isDirectory: false)
    FileManager.default.createFile(atPath: executableURL.path, contents: Data("#!/bin/sh\n".utf8))
}

private func helperExecutableURL(for helperURL: URL) -> URL {
    helperURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("MacOS", isDirectory: true)
        .appendingPathComponent("GlassEQSettings", isDirectory: false)
        .standardizedFileURL
}

private func settleAsyncWork() async {
    try? await Task.sleep(for: .milliseconds(20))
}

@MainActor
private func waitUntil(_ predicate: @MainActor () -> Bool) async {
    for _ in 0..<100 {
        if predicate() {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private enum TestAudioError: Error {
    case startFailed
    case updateFailed
    case defaultOutputUnavailable
}

@MainActor
private final class FakeWorkspaceOpener: WorkspaceOpening {
    private var results: [Bool]
    private(set) var openedURLs: [URL] = []

    init(results: [Bool]) {
        self.results = results
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        guard !results.isEmpty else {
            return true
        }
        return results.removeFirst()
    }
}

private struct FakeCodeSigningValidator: SettingsCodeSigningValidating {
    var signatures: [String: SettingsCodeSignatureInfo]

    func signatureInfo(for url: URL) throws -> SettingsCodeSignatureInfo {
        guard let signature = signatures[url.standardizedFileURL.path] else {
            throw SettingsCommandFailure(message: "Missing fake signature")
        }
        return signature
    }

    func signatureInfo(forProcessIdentifier processIdentifier: pid_t) throws -> SettingsCodeSignatureInfo {
        guard let signature = signatures["pid:\(processIdentifier)"] ?? signatures.values.first else {
            throw SettingsCommandFailure(message: "Missing fake process signature")
        }
        return signature
    }
}

private struct FailingSettingsHelperLaunchValidator: SettingsHelperLaunchValidating {
    func validatedExecutableURL(for helperURL: URL) throws -> URL {
        URL(fileURLWithPath: "/bin/sleep")
    }

    func validateRunningProcess(processIdentifier: pid_t, expectedHelperURL: URL) throws {
        throw SettingsCommandFailure(message: "Intentional post-launch validation failure")
    }
}

private struct PermissiveSettingsHelperLaunchValidator: SettingsHelperLaunchValidating {
    func validatedExecutableURL(for helperURL: URL) throws -> URL {
        URL(fileURLWithPath: "/usr/bin/true")
    }

    func validateRunningProcess(processIdentifier: pid_t, expectedHelperURL: URL) throws {}
}

private struct PermissionDeniedSettingsHelperLauncher: SettingsHelperLaunching {
    func launch(
        executableURL: URL,
        arguments: [String],
        terminationHandler: @escaping @Sendable (Process) -> Void
    ) throws -> SettingsHelperLaunch {
        throw POSIXError(.EPERM)
    }
}

private final class ControllableSettingsHelperLauncher: SettingsHelperLaunching {
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()

    func launch(
        executableURL: URL,
        arguments: [String],
        terminationHandler: @escaping @Sendable (Process) -> Void
    ) throws -> SettingsHelperLaunch {
        SettingsHelperLaunch(process: Process(), input: input, output: output, error: error)
    }

    func writeHelperOutput(_ data: Data) throws {
        try output.fileHandleForWriting.write(contentsOf: data)
    }

    func closeHelperOutput() throws {
        try output.fileHandleForWriting.close()
    }

    func readHostMessages() throws -> [SettingsPipeMessage] {
        let data = input.fileHandleForReading.availableData
        return try data.split(separator: 0x0A).map { line in
            try SettingsPipeCodec.decodeLine(Data(line))
        }
    }
}

private final class ClosedInputSettingsHelperLauncher: SettingsHelperLaunching {
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()

    init() throws {
        try input.fileHandleForReading.close()
    }

    func launch(
        executableURL: URL,
        arguments: [String],
        terminationHandler: @escaping @Sendable (Process) -> Void
    ) throws -> SettingsHelperLaunch {
        SettingsHelperLaunch(process: Process(), input: input, output: output, error: error)
    }
}

private final class SleepingSettingsHelperLauncher: SettingsHelperLaunching {
    private(set) var launchedProcesses: [Process] = []

    func launch(
        executableURL: URL,
        arguments: [String],
        terminationHandler: @escaping @Sendable (Process) -> Void
    ) throws -> SettingsHelperLaunch {
        let process = Process()
        let helperInput = Pipe()
        let helperOutput = Pipe()
        let helperError = Pipe()
        process.executableURL = executableURL
        process.arguments = ["60"]
        process.standardInput = helperInput.fileHandleForReading
        process.standardOutput = helperOutput.fileHandleForWriting
        process.standardError = helperError.fileHandleForWriting
        process.terminationHandler = terminationHandler
        try process.run()
        launchedProcesses.append(process)
        return SettingsHelperLaunch(
            process: process,
            input: helperInput,
            output: helperOutput,
            error: helperError
        )
    }
}

private final class FakeDefaultOutputLookup: DefaultOutputLookingUp, @unchecked Sendable {
    private let lock = NSLock()
    private var _defaultOutputCalls = 0
    private var _result: Result<AudioOutputDevice, Error>

    private(set) var defaultOutputCalls: Int {
        get { withLock { _defaultOutputCalls } }
        set { withLock { _defaultOutputCalls = newValue } }
    }

    var result: Result<AudioOutputDevice, Error> {
        get { withLock { _result } }
        set { withLock { _result = newValue } }
    }

    init(_ result: Result<AudioOutputDevice, Error>) {
        self._result = result
    }

    func defaultOutputDevice() throws -> AudioOutputDevice {
        let result = withLock {
            _defaultOutputCalls += 1
            return _result
        }
        return try result.get()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class FakeDefaultOutputObserverFactory: DefaultOutputObservingMaking {
    private(set) var observers: [FakeDefaultOutputObserver] = []

    func makeObserver(onChange: @escaping DefaultOutputObserverHandler) -> any DefaultOutputObserving {
        let observer = FakeDefaultOutputObserver(onChange: onChange)
        observers.append(observer)
        return observer
    }
}

private final class FakeDefaultOutputObserver: DefaultOutputObserving, @unchecked Sendable {
    private let onChange: DefaultOutputObserverHandler
    private let lock = NSLock()
    private var _startCalls: [Bool] = []
    private var _stopCallCount = 0

    var startCalls: [Bool] {
        withLock {
            _startCalls
        }
    }

    var stopCallCount: Int {
        withLock {
            _stopCallCount
        }
    }

    init(onChange: @escaping DefaultOutputObserverHandler) {
        self.onChange = onChange
    }

    func start(sendInitialValue: Bool) throws {
        withLock {
            _startCalls.append(sendInitialValue)
        }
    }

    func stop() {
        withLock {
            _stopCallCount += 1
        }
    }

    func emit(_ result: Result<AudioOutputDevice, Error>) {
        onChange(result)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return body()
    }
}

private final class BlockingAsyncDefaultOutputObserverFactory: DefaultOutputObservingMaking {
    private(set) var observers: [BlockingAsyncDefaultOutputObserver] = []

    func makeObserver(onChange: @escaping DefaultOutputObserverHandler) -> any DefaultOutputObserving {
        let observer = BlockingAsyncDefaultOutputObserver(onChange: onChange)
        observers.append(observer)
        return observer
    }
}

private final class BlockingAsyncDefaultOutputObserver: DefaultOutputObserving, @unchecked Sendable {
    private let onChange: DefaultOutputObserverHandler
    private let lock = NSLock()
    private var _startCalls: [Bool] = []
    private var _stopCallCount = 0
    private var startContinuation: CheckedContinuation<Void, Never>?

    init(onChange: @escaping DefaultOutputObserverHandler) {
        self.onChange = onChange
    }

    var startCalls: [Bool] {
        withLock {
            _startCalls
        }
    }

    var stopCallCount: Int {
        withLock {
            _stopCallCount
        }
    }

    func start(sendInitialValue: Bool) throws {
        withLock {
            _startCalls.append(sendInitialValue)
        }
    }

    func startAsync(sendInitialValue: Bool) async throws {
        try start(sendInitialValue: sendInitialValue)
        await withCheckedContinuation { continuation in
            withLock {
                startContinuation = continuation
            }
        }
    }

    func stop() {
        withLock {
            _stopCallCount += 1
        }
    }

    func stopAsync() async {
        stop()
    }

    func emit(_ result: Result<AudioOutputDevice, Error>) {
        onChange(result)
    }

    func resumeStart() {
        let continuation = withLock {
            let continuation = startContinuation
            startContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return body()
    }
}

private final class FakeAudioEngine: AudioEngineControlling, @unchecked Sendable {
    struct StartCall: Equatable {
        var output: AudioOutputDevice
        var profile: EQProfile
    }

    private let lock = NSLock()
    private var _state: AudioEngineState = .stopped
    private var _startError: Error?
    private var _updateError: Error?
    private var _updateErrorPreservesRunningState = false
    private var _updateDSPResult = true
    private var _startDelaySeconds: TimeInterval = 0
    private var _startDelaySecondsByUID: [String: TimeInterval] = [:]
    private var _startBlockersByUID: [String: FakeStartBlocker] = [:]
    private var _startCalls: [StartCall] = []
    private var _updateCalls: [EQProfile] = []
    private var _updateDSPCalls: [EQProfile] = []
    private var _stopCallCount = 0
    private var _muteOutputCallCount = 0
    private var _setBypassedCalls: [Bool] = []
    private var _metrics = AudioEngineMetrics()
    private var _events: [String] = []

    var state: AudioEngineState {
        get { withLock { _state } }
        set { withLock { _state = newValue } }
    }

    var startError: Error? {
        get { withLock { _startError } }
        set { withLock { _startError = newValue } }
    }

    var updateError: Error? {
        get { withLock { _updateError } }
        set { withLock { _updateError = newValue } }
    }

    var updateErrorPreservesRunningState: Bool {
        get { withLock { _updateErrorPreservesRunningState } }
        set { withLock { _updateErrorPreservesRunningState = newValue } }
    }

    var updateDSPResult: Bool {
        get { withLock { _updateDSPResult } }
        set { withLock { _updateDSPResult = newValue } }
    }

    var startDelaySeconds: TimeInterval {
        get { withLock { _startDelaySeconds } }
        set { withLock { _startDelaySeconds = newValue } }
    }

    var startDelaySecondsByUID: [String: TimeInterval] {
        get { withLock { _startDelaySecondsByUID } }
        set { withLock { _startDelaySecondsByUID = newValue } }
    }

    private(set) var startCalls: [StartCall] {
        get { withLock { _startCalls } }
        set { withLock { _startCalls = newValue } }
    }

    private(set) var updateCalls: [EQProfile] {
        get { withLock { _updateCalls } }
        set { withLock { _updateCalls = newValue } }
    }

    private(set) var updateDSPCalls: [EQProfile] {
        get { withLock { _updateDSPCalls } }
        set { withLock { _updateDSPCalls = newValue } }
    }

    private(set) var stopCallCount: Int {
        get { withLock { _stopCallCount } }
        set { withLock { _stopCallCount = newValue } }
    }

    private(set) var muteOutputCallCount: Int {
        get { withLock { _muteOutputCallCount } }
        set { withLock { _muteOutputCallCount = newValue } }
    }

    private(set) var setBypassedCalls: [Bool] {
        get { withLock { _setBypassedCalls } }
        set { withLock { _setBypassedCalls = newValue } }
    }

    var metrics: AudioEngineMetrics {
        get { withLock { _metrics } }
        set { withLock { _metrics = newValue } }
    }

    var events: [String] {
        withLock { _events }
    }

    func blockStart(for outputUID: String) {
        withLock {
            _startBlockersByUID[outputUID] = FakeStartBlocker()
        }
    }

    func waitUntilStartIsBlocked(for outputUID: String, timeout: DispatchTime) -> Bool {
        withLock {
            _startBlockersByUID[outputUID]
        }?.waitUntilEntered(timeout: timeout) ?? false
    }

    func unblockStart(for outputUID: String) {
        let blocker = withLock {
            _startBlockersByUID.removeValue(forKey: outputUID)
        }
        blocker?.unblock()
    }

    func start(output: AudioOutputDevice, profile: EQProfile) throws {
        let startControl = withLock {
            _events.append("start:\(output.uid)")
            _startCalls.append(StartCall(output: output, profile: profile))
            return (
                delay: _startDelaySecondsByUID[output.uid] ?? _startDelaySeconds,
                blocker: _startBlockersByUID[output.uid]
            )
        }
        startControl.blocker?.waitUntilUnblocked()
        if startControl.delay > 0 {
            Thread.sleep(forTimeInterval: startControl.delay)
        }
        if let startError = withLock({ _startError }) {
            withLock {
                _state = .failed("Start failed")
            }
            throw startError
        }
        withLock {
            _state = .running(output: output)
        }
    }

    func update(profile: EQProfile) throws {
        let update = withLock {
            _events.append("update:\(profile.id)")
            _updateCalls.append(profile)
            return (error: _updateError, preservesRunningState: _updateErrorPreservesRunningState)
        }
        if let updateError = update.error {
            if !update.preservesRunningState {
                withLock {
                    _state = .failed("Update failed")
                }
            }
            throw updateError
        }
        withLock {
            if case .running(let output) = _state {
                _state = .running(output: output)
            }
        }
    }

    func updateDSP(profile: EQProfile) -> Bool {
        withLock {
            _events.append("updateDSP:\(profile.id)")
            _updateDSPCalls.append(profile)
            return _updateDSPResult
        }
    }

    func setBypassed(_ isBypassed: Bool) {
        withLock {
            _events.append("bypass:\(isBypassed)")
            _setBypassedCalls.append(isBypassed)
        }
    }

    func muteOutputForTransition() {
        withLock {
            _events.append("mute")
            _muteOutputCallCount += 1
        }
    }

    func stop() {
        withLock {
            _events.append("stop")
            _stopCallCount += 1
            _state = .stopped
        }
    }

    func snapshotMetrics() -> AudioEngineMetrics {
        withLock {
            _metrics
        }
    }

    func resetDiagnostics() {
        withLock {
            _metrics = AudioEngineMetrics()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class FakeStartBlocker: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func waitUntilUnblocked() {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
    }

    func waitUntilEntered(timeout: DispatchTime) -> Bool {
        entered.wait(timeout: timeout) == .success
    }

    func unblock() {
        release.signal()
    }
}
