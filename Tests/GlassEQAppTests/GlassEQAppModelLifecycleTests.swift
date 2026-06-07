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
    func staleAsyncStartCompletionDoesNotReplaceNewerRouteSwitch() async {
        let firstOutput = makeOutput(uid: "first-output", name: "First Output", id: 200)
        let secondOutput = makeOutput(uid: "second-output", name: "Second Output", id: 300)
        let engine = FakeAudioEngine()
        engine.startDelaySecondsByUID[firstOutput.uid] = 0.08
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

        lookup.result = .success(secondOutput)
        observer.emit(.success(secondOutput))
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
        engine.startDelaySeconds = 0.08
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

        model.stop()

        await waitUntil {
            engine.stopCallCount == 2
        }

        #expect(engine.stopCallCount == 2)
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
        let preview = makeProfile(name: "Preview During Wake")
        let store = ProfileStore(
            profiles: [fallback, applied, mapped, preview],
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

        engine.startDelaySeconds = 0.08
        model.handleWillSleep()
        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 2 && observers.observers[1].startCalls == [true]
        }
        observers.observers[1].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .waking && engine.startCalls.count == 2
        }

        try model.apply(profile: applied)
        try model.useForCurrentOutput(profile: mapped)
        model.setBypass(true)
        model.preview(profile: preview)
        model.stopPreview()

        #expect(model.lifecycleState == .waking)
        #expect(model.activeProfile.id == mapped.id)
        #expect(model.activeProfile.isBypassed)
        #expect(model.previewReturnProfile == nil)
        #expect(engine.updateCalls.isEmpty)
        #expect(engine.updateDSPCalls.isEmpty)
        #expect(engine.setBypassedCalls.isEmpty)
        #expect(model.profileStore.profile(forOutputUID: output.uid).id == mapped.id)

        await waitUntil {
            model.lifecycleState == .running
                && engine.startCalls.last?.profile.id == mapped.id
                && engine.startCalls.last?.profile.isBypassed == true
        }

        #expect(model.isRunning)
        #expect(model.statusMessage == localized("Processing \(output.name) with \(mapped.name)"))
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
        engine.metrics = AudioEngineMetrics(capturedFrames: 123, playedFrames: 100)
        let model = makeModel(engine: engine)

        let response = try await model.performSettingsCommand(.startMetricsPolling)

        #expect(response.snapshot == nil)
        #expect(model.engineMetrics.capturedFrames == 123)
        #expect(model.engineMetrics.playedFrames == 100)
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
    func settingsLaunchValidationFailureTerminatesPartiallyStartedHelper() async throws {
        let model = makeModel()
        let launcher = SleepingSettingsHelperLauncher()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: launcher,
            helperValidator: FailingSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        coordinator.openSettings()

        let process = try #require(launcher.launchedProcesses.first)
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        #expect(!coordinator.hasActiveSessionResourcesForTesting)
        for _ in 0..<250 {
            if !process.isRunning {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!process.isRunning)
        #expect(model.statusMessage.contains("Settings failed to open"))
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
    observers: FakeDefaultOutputObserverFactory = FakeDefaultOutputObserverFactory(),
    workspaceOpener: any WorkspaceOpening = FakeWorkspaceOpener(results: []),
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
        saveDebounceDelay: saveDelay,
        outputChangeSettlingDelayOverride: outputDelay,
        wakeReconnectDelayOverride: wakeDelay
    )
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
    private(set) var defaultOutputCalls = 0
    var result: Result<AudioOutputDevice, Error>

    init(_ result: Result<AudioOutputDevice, Error>) {
        self.result = result
    }

    func defaultOutputDevice() throws -> AudioOutputDevice {
        defaultOutputCalls += 1
        return try result.get()
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

private final class FakeDefaultOutputObserver: DefaultOutputObserving {
    private let onChange: DefaultOutputObserverHandler
    private(set) var startCalls: [Bool] = []
    private(set) var stopCallCount = 0

    init(onChange: @escaping DefaultOutputObserverHandler) {
        self.onChange = onChange
    }

    func start(sendInitialValue: Bool) throws {
        startCalls.append(sendInitialValue)
    }

    func stop() {
        stopCallCount += 1
    }

    func emit(_ result: Result<AudioOutputDevice, Error>) {
        onChange(result)
    }
}

private final class FakeAudioEngine: AudioEngineControlling, @unchecked Sendable {
    struct StartCall: Equatable {
        var output: AudioOutputDevice
        var profile: EQProfile
    }

    var state: AudioEngineState = .stopped
    var startError: Error?
    var updateError: Error?
    var updateDSPResult = true
    var startDelaySeconds: TimeInterval = 0
    var startDelaySecondsByUID: [String: TimeInterval] = [:]
    private(set) var startCalls: [StartCall] = []
    private(set) var updateCalls: [EQProfile] = []
    private(set) var updateDSPCalls: [EQProfile] = []
    private(set) var stopCallCount = 0
    private(set) var muteOutputCallCount = 0
    private(set) var setBypassedCalls: [Bool] = []
    var metrics = AudioEngineMetrics()

    func start(output: AudioOutputDevice, profile: EQProfile) throws {
        startCalls.append(StartCall(output: output, profile: profile))
        let delay = startDelaySecondsByUID[output.uid] ?? startDelaySeconds
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        if let startError {
            state = .failed("Start failed")
            throw startError
        }
        state = .running(output: output)
    }

    func update(profile: EQProfile) throws {
        updateCalls.append(profile)
        if let updateError {
            state = .failed("Update failed")
            throw updateError
        }
        if case .running(let output) = state {
            state = .running(output: output)
        }
    }

    func updateDSP(profile: EQProfile) -> Bool {
        updateDSPCalls.append(profile)
        return updateDSPResult
    }

    func setBypassed(_ isBypassed: Bool) {
        setBypassedCalls.append(isBypassed)
    }

    func muteOutputForTransition() {
        muteOutputCallCount += 1
    }

    func stop() {
        stopCallCount += 1
        state = .stopped
    }

    func snapshotMetrics() -> AudioEngineMetrics {
        metrics
    }

    func resetDiagnostics() {
        metrics = AudioEngineMetrics()
    }
}
