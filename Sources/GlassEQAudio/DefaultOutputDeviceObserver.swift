import CoreAudio
import Foundation

public final class DefaultOutputDeviceObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.glasseq.default-output-observer")
    private let queueSpecific = DispatchSpecificKey<Void>()
    private var systemListeners: [ListenerToken] = []
    private var outputListeners: [ListenerToken] = []
    private var observedOutputID = AudioObjectID(kAudioObjectUnknown)
    private var isStarted = false
    private let onChange: @Sendable (Result<AudioOutputDevice, Error>) -> Void

    private struct ListenerToken {
        var objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        var listener: AudioObjectPropertyListenerBlock
    }

    public init(onChange: @escaping @Sendable (Result<AudioOutputDevice, Error>) -> Void) {
        self.onChange = onChange
        queue.setSpecific(key: queueSpecific, value: ())
    }

    deinit {
        stop()
    }

    public func start(sendInitialValue: Bool = true) throws {
        try performOnQueue {
            try startOnQueue(sendInitialValue: sendInitialValue)
        }
    }

    public func stop() {
        performOnQueue {
            stopOnQueue()
        }
    }

    private func performOnQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueSpecific) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    private func startOnQueue(sendInitialValue: Bool) throws {
        guard !isStarted else {
            if sendInitialValue {
                refreshObservedOutput(sendChange: true)
            }
            return
        }

        try addSystemListener(
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            operation: "AudioObjectAddPropertyListenerBlock(default output)"
        )
        isStarted = true

        refreshObservedOutput(sendChange: sendInitialValue)
    }

    private func stopOnQueue() {
        removeOutputListeners()
        removeListeners(&systemListeners)
        isStarted = false
    }

    private func refreshObservedOutput(sendChange: Bool) {
        guard isStarted else {
            return
        }

        do {
            let output = try CoreAudioDeviceQuery.defaultOutputDevice()
            try observeOutputChanges(for: output.id)
            if sendChange {
                onChange(.success(output))
            }
        } catch {
            removeOutputListeners()
            if sendChange {
                onChange(.failure(error))
            }
        }
    }

    private func observeOutputChanges(for outputID: AudioObjectID) throws {
        guard outputID != observedOutputID || outputListeners.isEmpty else {
            return
        }

        removeOutputListeners()

        try addOutputListener(
            outputID: outputID,
            selector: kAudioDevicePropertyNominalSampleRate,
            scope: kAudioObjectPropertyScopeGlobal,
            operation: "AudioObjectAddPropertyListenerBlock(output sample rate)"
        )
        try addOutputListener(
            outputID: outputID,
            selector: kAudioDevicePropertyBufferFrameSize,
            scope: kAudioObjectPropertyScopeGlobal,
            operation: "AudioObjectAddPropertyListenerBlock(output buffer frame size)"
        )
        try addOutputListener(
            outputID: outputID,
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeOutput,
            operation: "AudioObjectAddPropertyListenerBlock(output stream configuration)"
        )
        try addOutputListener(
            outputID: outputID,
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal,
            operation: "AudioObjectAddPropertyListenerBlock(output alive)"
        )
        observedOutputID = outputID
    }

    private func addSystemListener(selector: AudioObjectPropertySelector, operation: String) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshObservedOutput(sendChange: true)
        }
        try checkOSStatus(
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener
            ),
            operation: operation
        )
        systemListeners.append(ListenerToken(objectID: AudioObjectID(kAudioObjectSystemObject), address: address, listener: listener))
    }

    private func addOutputListener(
        outputID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        operation: String
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self,
                  self.isStarted,
                  self.observedOutputID == outputID else {
                return
            }

            if Self.shouldSuppressSelfInducedOutputChange(
                selector: selector,
                deviceID: outputID,
                selfChangeGuard: CoreAudioSelfChangeGuard.shared
            ) {
                return
            }

            guard selector != kAudioDevicePropertyDeviceIsAlive else {
                do {
                    guard try CoreAudioDeviceQuery.isDeviceAlive(id: outputID) else {
                        self.refreshObservedOutput(sendChange: true)
                        return
                    }
                } catch {
                    self.refreshObservedOutput(sendChange: true)
                    return
                }
                self.refreshObservedOutput(sendChange: true)
                return
            }
            self.refreshObservedOutput(sendChange: true)
        }
        try checkOSStatus(
            AudioObjectAddPropertyListenerBlock(
                outputID,
                &address,
                queue,
                listener
            ),
            operation: operation
        )
        outputListeners.append(ListenerToken(objectID: outputID, address: address, listener: listener))
    }

    static func shouldSuppressSelfInducedOutputChange(
        selector: AudioObjectPropertySelector,
        deviceID: AudioObjectID,
        selfChangeGuard: CoreAudioSelfChangeGuard
    ) -> Bool {
        // Ignore changes we caused ourselves (our own buffer-size / sample-rate writes during
        // a rebuild) so we don't loop reacting to our own device reconfiguration. Device-alive
        // changes are never suppressed — a real disconnect must always be handled.
        selector != kAudioDevicePropertyDeviceIsAlive && selfChangeGuard.isSelfChange(deviceID: deviceID)
    }

    private func removeOutputListeners() {
        removeListeners(&outputListeners)
        observedOutputID = AudioObjectID(kAudioObjectUnknown)
    }

    private func removeListeners(_ listeners: inout [ListenerToken]) {
        for listener in listeners {
            var address = listener.address
            _ = AudioObjectRemovePropertyListenerBlock(
                listener.objectID,
                &address,
                queue,
                listener.listener
            )
        }
        listeners.removeAll()
    }
}
