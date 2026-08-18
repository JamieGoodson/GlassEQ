import Foundation

public struct EQChannelConfiguration: Equatable, Sendable {
    public var preampLinearGain: Float
    public var coefficients: [BiquadCoefficients]

    public init(
        preampDB: Double,
        filters: [EQFilter],
        sampleRate: Double,
        maximumUsableFrequency: Double? = nil
    ) {
        self.preampLinearGain = Float(pow(10, preampDB / 20))
        self.coefficients = filters
            .filter(\.isEnabled)
            .map {
                BiquadCoefficients.make(
                    filter: $0,
                    sampleRate: sampleRate,
                    maximumUsableFrequency: maximumUsableFrequency
                )
            }
    }
}

public struct EQConfiguration: Equatable, Sendable {
    public var sampleRate: Double
    public var maximumUsableFrequency: Double
    public var channelCount: Int
    public var preampLinearGain: Float
    public var coefficients: [BiquadCoefficients]
    public var channelConfigurations: [EQChannelConfiguration]
    public var isBypassed: Bool

    public init(
        profile: EQProfile,
        sampleRate: Double,
        channelCount: Int,
        maximumUsableFrequency: Double? = nil
    ) {
        self.sampleRate = sampleRate
        self.maximumUsableFrequency = min(
            EQRouteFrequencyPolicy.maximumUsableFrequency(sampleRate: sampleRate),
            maximumUsableFrequency ?? .greatestFiniteMagnitude
        )
        self.channelCount = max(channelCount, 1)
        let linkedConfiguration = EQChannelConfiguration(
            preampDB: profile.preampDB,
            filters: profile.filters,
            sampleRate: sampleRate,
            maximumUsableFrequency: self.maximumUsableFrequency
        )
        self.preampLinearGain = linkedConfiguration.preampLinearGain
        self.coefficients = linkedConfiguration.coefficients
        self.channelConfigurations = Self.makeChannelConfigurations(
            profile: profile,
            sampleRate: sampleRate,
            maximumUsableFrequency: self.maximumUsableFrequency,
            channelCount: self.channelCount,
            linkedConfiguration: linkedConfiguration
        )
        self.isBypassed = profile.isBypassed
    }

    private static func makeChannelConfigurations(
        profile: EQProfile,
        sampleRate: Double,
        maximumUsableFrequency: Double,
        channelCount: Int,
        linkedConfiguration: EQChannelConfiguration
    ) -> [EQChannelConfiguration] {
        guard profile.channelMode == .stereo else {
            return Array(repeating: linkedConfiguration, count: channelCount)
        }

        let left = EQChannelConfiguration(
            preampDB: profile.leftPreampDB,
            filters: profile.leftFilters,
            sampleRate: sampleRate,
            maximumUsableFrequency: maximumUsableFrequency
        )
        let right = EQChannelConfiguration(
            preampDB: profile.rightPreampDB,
            filters: profile.rightFilters,
            sampleRate: sampleRate,
            maximumUsableFrequency: maximumUsableFrequency
        )

        return (0..<channelCount).map { channel in
            switch channel {
            case 0:
                left
            case 1:
                right
            default:
                linkedConfiguration
            }
        }
    }
}

public struct EQRenderConfiguration: Equatable, Sendable {
    public var configuration: EQConfiguration
    var coefficients: [RenderBiquadCoefficients]
    var channelStarts: [Int]
    var channelFilterCounts: [Int]
    var preampLinearGains: [Float]

    public init(
        profile: EQProfile,
        sampleRate: Double,
        channelCount: Int,
        maximumUsableFrequency: Double? = nil
    ) {
        self.init(configuration: EQConfiguration(
            profile: profile,
            sampleRate: sampleRate,
            channelCount: channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        ))
    }

    public init(configuration: EQConfiguration) {
        self.configuration = configuration
        let renderLayout = EQProcessor.makeRenderLayout(configuration: configuration)
        self.coefficients = renderLayout.coefficients
        self.channelStarts = renderLayout.channelStarts
        self.channelFilterCounts = renderLayout.channelFilterCounts
        self.preampLinearGains = renderLayout.preampLinearGains
    }

    public func hasRealtimeCompatibleTopology(with other: EQRenderConfiguration) -> Bool {
        configuration.sampleRate == other.configuration.sampleRate
            && configuration.channelCount == other.configuration.channelCount
            && channelFilterCounts == other.channelFilterCounts
    }
}

public struct EQProcessorRetiredRenderStorage: Sendable {
    private let configuration: EQConfiguration
    private let coefficients: [RenderBiquadCoefficients]
    private let channelStarts: [Int]
    private let channelFilterCounts: [Int]
    private let preampLinearGains: [Float]

    fileprivate init(
        configuration: EQConfiguration,
        coefficients: [RenderBiquadCoefficients],
        channelStarts: [Int],
        channelFilterCounts: [Int],
        preampLinearGains: [Float]
    ) {
        self.configuration = configuration
        self.coefficients = coefficients
        self.channelStarts = channelStarts
        self.channelFilterCounts = channelFilterCounts
        self.preampLinearGains = preampLinearGains
    }
}

public struct EQProcessor: Sendable {
    public private(set) var configuration: EQConfiguration
    private var coefficients: [RenderBiquadCoefficients]
    private var states: [BiquadState]
    private var channelStarts: [Int]
    private var channelFilterCounts: [Int]
    private var preampLinearGains: [Float]

    public init(configuration: EQConfiguration) {
        self.init(renderConfiguration: EQRenderConfiguration(configuration: configuration))
    }

    public init(renderConfiguration: EQRenderConfiguration) {
        self.configuration = renderConfiguration.configuration
        self.coefficients = renderConfiguration.coefficients
        self.states = Array(repeating: BiquadState(), count: renderConfiguration.coefficients.count)
        self.channelStarts = renderConfiguration.channelStarts
        self.channelFilterCounts = renderConfiguration.channelFilterCounts
        self.preampLinearGains = renderConfiguration.preampLinearGains
    }

    public mutating func update(configuration: EQConfiguration) {
        applyPreparedConfiguration(EQRenderConfiguration(configuration: configuration))
    }

    public mutating func applyPreparedConfiguration(_ renderConfiguration: EQRenderConfiguration) {
        let previousCoefficients = coefficients
        // Keep this comparison allocation-free; audio callbacks use it for same-topology DSP swaps.
        let needsStateReset = renderConfiguration.configuration.channelCount != self.configuration.channelCount
            || renderConfiguration.channelFilterCounts != channelFilterCounts
            || renderConfiguration.configuration.sampleRate != self.configuration.sampleRate

        self.configuration = renderConfiguration.configuration
        coefficients = renderConfiguration.coefficients
        channelStarts = renderConfiguration.channelStarts
        channelFilterCounts = renderConfiguration.channelFilterCounts
        preampLinearGains = renderConfiguration.preampLinearGains

        if needsStateReset {
            states = Array(repeating: BiquadState(), count: renderConfiguration.coefficients.count)
        } else {
            resetChangedFilterStates(previousCoefficients: previousCoefficients, nextCoefficients: renderConfiguration.coefficients)
        }
    }

    public mutating func applyRealtimeCompatiblePreparedConfiguration(
        _ renderConfiguration: EQRenderConfiguration
    ) -> EQProcessorRetiredRenderStorage? {
        guard renderConfiguration.configuration.sampleRate == configuration.sampleRate,
              renderConfiguration.configuration.channelCount == configuration.channelCount,
              renderConfiguration.channelFilterCounts == channelFilterCounts,
              renderConfiguration.coefficients.count == coefficients.count,
              renderConfiguration.channelStarts.count == channelStarts.count,
              renderConfiguration.preampLinearGains.count == preampLinearGains.count,
              states.count == coefficients.count else {
            return nil
        }

        let retiredStorage = EQProcessorRetiredRenderStorage(
            configuration: configuration,
            coefficients: coefficients,
            channelStarts: channelStarts,
            channelFilterCounts: channelFilterCounts,
            preampLinearGains: preampLinearGains
        )
        let previousCoefficients = coefficients

        configuration = renderConfiguration.configuration
        coefficients = renderConfiguration.coefficients
        channelStarts = renderConfiguration.channelStarts
        channelFilterCounts = renderConfiguration.channelFilterCounts
        preampLinearGains = renderConfiguration.preampLinearGains

        for index in coefficients.indices {
            if previousCoefficients[index] != coefficients[index] {
                states[index] = BiquadState()
            }
        }

        return retiredStorage
    }

    private mutating func resetChangedFilterStates(
        previousCoefficients: [RenderBiquadCoefficients],
        nextCoefficients: [RenderBiquadCoefficients]
    ) {
        guard previousCoefficients.count == nextCoefficients.count,
              states.count == nextCoefficients.count else {
            states = Array(repeating: BiquadState(), count: nextCoefficients.count)
            return
        }

        for index in nextCoefficients.indices where previousCoefficients[index] != nextCoefficients[index] {
            states[index] = BiquadState()
        }
    }

    public mutating func processInterleaved(_ samples: inout [Float], channelCount: Int) {
        guard !configuration.isBypassed else {
            return
        }

        let sourceChannelCount = max(channelCount, 1)
        let frameCount = samples.count / sourceChannelCount
        samples.withUnsafeMutableBufferPointer {
            _ = processInterleavedWithDiagnostics($0, frameCount: frameCount, channelCount: sourceChannelCount)
        }

        let remainingSampleStart = frameCount * sourceChannelCount
        if remainingSampleStart < samples.count {
            for channel in 0..<(samples.count - remainingSampleStart) {
                samples[remainingSampleStart + channel] = processSample(samples[remainingSampleStart + channel], channel: channel)
            }
        }
    }

    public mutating func processInterleavedWithDiagnostics(
        _ samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) -> UInt64 {
        guard !configuration.isBypassed else {
            return 0
        }

        let sourceChannelCount = max(channelCount, 1)
        let availableFrames = min(frameCount, samples.count / sourceChannelCount)
        guard availableFrames > 0 else {
            return 0
        }

        if sourceChannelCount == 2, channelStarts.count >= 2 {
            return withRenderBuffers { stateBuffer, coefficientBuffer, channelStartBuffer, channelFilterCountBuffer, preampLinearGainBuffer in
                Self.processStereoInterleaved(
                    samples,
                    frameCount: availableFrames,
                    states: stateBuffer,
                    coefficients: coefficientBuffer,
                    channelStarts: channelStartBuffer,
                    channelFilterCounts: channelFilterCountBuffer,
                    preampLinearGains: preampLinearGainBuffer
                )
            }
        }

        return withRenderBuffers { stateBuffer, coefficientBuffer, channelStartBuffer, channelFilterCountBuffer, preampLinearGainBuffer in
            var saturatedSamples: UInt64 = 0
            let channels = min(sourceChannelCount, channelStartBuffer.count)
            var sampleIndex = 0
            for _ in 0..<availableFrames {
                for channel in 0..<channels {
                    let processed = Self.processSampleWithDiagnosticsUnchecked(
                        samples[sampleIndex + channel],
                        channel: channel,
                        states: stateBuffer,
                        coefficients: coefficientBuffer,
                        channelStarts: channelStartBuffer,
                        channelFilterCounts: channelFilterCountBuffer,
                        preampLinearGains: preampLinearGainBuffer
                    )
                    samples[sampleIndex + channel] = processed.sample
                    if processed.saturated {
                        saturatedSamples += 1
                    }
                }
                sampleIndex += sourceChannelCount
            }
            return saturatedSamples
        }
    }

    public mutating func processNonInterleaved(_ channels: inout [[Float]]) {
        guard !configuration.isBypassed else {
            return
        }

        withRenderBuffers { stateBuffer, coefficientBuffer, channelStartBuffer, channelFilterCountBuffer, preampLinearGainBuffer in
            for channelIndex in channels.indices {
                guard channelIndex < channelStartBuffer.count else {
                    continue
                }
                for sampleIndex in channels[channelIndex].indices {
                    channels[channelIndex][sampleIndex] = Self.processSampleWithDiagnosticsUnchecked(
                        channels[channelIndex][sampleIndex],
                        channel: channelIndex,
                        states: stateBuffer,
                        coefficients: coefficientBuffer,
                        channelStarts: channelStartBuffer,
                        channelFilterCounts: channelFilterCountBuffer,
                        preampLinearGains: preampLinearGainBuffer
                    ).sample
                }
            }
        }
    }

    public mutating func processSample(_ input: Float, channel: Int) -> Float {
        processSampleWithDiagnostics(input, channel: channel).sample
    }

    public mutating func processSampleWithDiagnostics(_ input: Float, channel: Int) -> (sample: Float, saturated: Bool) {
        guard !configuration.isBypassed else {
            return (input, false)
        }

        guard channel >= 0, channel < channelStarts.count else {
            return (input, false)
        }
        return withRenderBuffers { stateBuffer, coefficientBuffer, channelStartBuffer, channelFilterCountBuffer, preampLinearGainBuffer in
            Self.processSampleWithDiagnosticsUnchecked(
                input,
                channel: channel,
                states: stateBuffer,
                coefficients: coefficientBuffer,
                channelStarts: channelStartBuffer,
                channelFilterCounts: channelFilterCountBuffer,
                preampLinearGains: preampLinearGainBuffer
            )
        }
    }

    private mutating func withRenderBuffers<Result>(
        _ body: (
            UnsafeMutableBufferPointer<BiquadState>,
            UnsafeBufferPointer<RenderBiquadCoefficients>,
            UnsafeBufferPointer<Int>,
            UnsafeBufferPointer<Int>,
            UnsafeBufferPointer<Float>
        ) -> Result
    ) -> Result {
        coefficients.withUnsafeBufferPointer { coefficientBuffer in
            channelStarts.withUnsafeBufferPointer { channelStartBuffer in
                channelFilterCounts.withUnsafeBufferPointer { channelFilterCountBuffer in
                    preampLinearGains.withUnsafeBufferPointer { preampLinearGainBuffer in
                        states.withUnsafeMutableBufferPointer { stateBuffer in
                            body(
                                stateBuffer,
                                coefficientBuffer,
                                channelStartBuffer,
                                channelFilterCountBuffer,
                                preampLinearGainBuffer
                            )
                        }
                    }
                }
            }
        }
    }

    private static func processStereoInterleaved(
        _ samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        states: UnsafeMutableBufferPointer<BiquadState>,
        coefficients: UnsafeBufferPointer<RenderBiquadCoefficients>,
        channelStarts: UnsafeBufferPointer<Int>,
        channelFilterCounts: UnsafeBufferPointer<Int>,
        preampLinearGains: UnsafeBufferPointer<Float>
    ) -> UInt64 {
        var saturatedSamples: UInt64 = 0
        var sampleIndex = 0
        for _ in 0..<frameCount {
            let left = processSampleWithDiagnosticsUnchecked(
                samples[sampleIndex],
                channel: 0,
                states: states,
                coefficients: coefficients,
                channelStarts: channelStarts,
                channelFilterCounts: channelFilterCounts,
                preampLinearGains: preampLinearGains
            )
            samples[sampleIndex] = left.sample
            if left.saturated {
                saturatedSamples += 1
            }

            let right = processSampleWithDiagnosticsUnchecked(
                samples[sampleIndex + 1],
                channel: 1,
                states: states,
                coefficients: coefficients,
                channelStarts: channelStarts,
                channelFilterCounts: channelFilterCounts,
                preampLinearGains: preampLinearGains
            )
            samples[sampleIndex + 1] = right.sample
            if right.saturated {
                saturatedSamples += 1
            }

            sampleIndex += 2
        }
        return saturatedSamples
    }

    private static func processSampleWithDiagnosticsUnchecked(
        _ input: Float,
        channel: Int,
        states: UnsafeMutableBufferPointer<BiquadState>,
        coefficients: UnsafeBufferPointer<RenderBiquadCoefficients>,
        channelStarts: UnsafeBufferPointer<Int>,
        channelFilterCounts: UnsafeBufferPointer<Int>,
        preampLinearGains: UnsafeBufferPointer<Float>
    ) -> (sample: Float, saturated: Bool) {
        guard channel >= 0, channel < channelStarts.count else {
            return (input, false)
        }
        let start = channelStarts[channel]
        let count = channelFilterCounts[channel]
        var value = input * preampLinearGains[channel]

        for filterOffset in 0..<count {
            let index = start + filterOffset
            value = states[index].process(value, coefficients: coefficients[index])
        }

        return Self.saturate(value)
    }

    private static func saturate(_ value: Float) -> (sample: Float, saturated: Bool) {
        guard value.isFinite else {
            return (0, true)
        }

        let threshold: Float = 0.98
        if value > threshold {
            return (
                threshold + (1 - threshold) * tanh((value - threshold) / (1 - threshold)),
                true
            )
        }
        if value < -threshold {
            return (
                -threshold + (1 - threshold) * tanh((value + threshold) / (1 - threshold)),
                true
            )
        }
        return (value, false)
    }

    static func makeRenderLayout(configuration: EQConfiguration) -> (
        coefficients: [RenderBiquadCoefficients],
        states: [BiquadState],
        channelStarts: [Int],
        channelFilterCounts: [Int],
        preampLinearGains: [Float]
    ) {
        var coefficients: [RenderBiquadCoefficients] = []
        var channelStarts: [Int] = []
        var channelFilterCounts: [Int] = []
        var preampLinearGains: [Float] = []

        for channelConfiguration in configuration.channelConfigurations {
            channelStarts.append(coefficients.count)
            channelFilterCounts.append(channelConfiguration.coefficients.count)
            preampLinearGains.append(channelConfiguration.preampLinearGain)
            coefficients.append(contentsOf: channelConfiguration.coefficients.map(RenderBiquadCoefficients.init))
        }

        return (
            coefficients: coefficients,
            states: Array(repeating: BiquadState(), count: coefficients.count),
            channelStarts: channelStarts,
            channelFilterCounts: channelFilterCounts,
            preampLinearGains: preampLinearGains
        )
    }
}
