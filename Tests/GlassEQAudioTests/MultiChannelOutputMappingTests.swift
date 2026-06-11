import CoreAudio
import Foundation
@testable import GlassEQAudio
import Testing

@Suite
struct MultiChannelOutputMappingTests {
    @Test
    func playbackStereoPairNormalizesPreferredChannels() {
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: nil, outputChannelCount: 6) == (0, 1))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: (1, 2), outputChannelCount: 6) == (0, 1))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: (3, 4), outputChannelCount: 6) == (2, 3))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: (0, 0), outputChannelCount: 6) == (0, 1))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: (7, 8), outputChannelCount: 6) == (0, 1))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: (3, 3), outputChannelCount: 6) == (0, 1))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: (2, 1), outputChannelCount: 2) == (1, 0))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: (3, 4), outputChannelCount: 1) == (0, 0))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: nil, outputChannelCount: 1) == (0, 0))
    }

    @Test
    func playbackChannelPairEncodingRoundTripsAndClamps() {
        #expect(SystemTapAudioEngine.decodedPlaybackChannelPair(
            SystemTapAudioEngine.encodedPlaybackChannelPair(left: 0, right: 1)
        ) == (0, 1))
        #expect(SystemTapAudioEngine.decodedPlaybackChannelPair(
            SystemTapAudioEngine.encodedPlaybackChannelPair(left: 2, right: 3)
        ) == (2, 3))
        #expect(SystemTapAudioEngine.decodedPlaybackChannelPair(
            SystemTapAudioEngine.encodedPlaybackChannelPair(left: 255, right: 255)
        ) == (255, 255))
        #expect(SystemTapAudioEngine.decodedPlaybackChannelPair(
            SystemTapAudioEngine.encodedPlaybackChannelPair(left: -5, right: 999)
        ) == (0, 255))
    }

    @Test
    func stereoSourceMapsToFirstPairOfInterleavedSixChannelBuffer() {
        let written = mappedCopy(
            source: [1, 2, 3, 4],
            sourceChannelCount: 2,
            channelLayout: [6],
            frames: 3,
            destinationFrameOffset: 1,
            frameCount: 2
        )

        #expect(written == [[
            -1, -1, -1, -1, -1, -1,
            1, 2, 0, 0, 0, 0,
            3, 4, 0, 0, 0, 0
        ]])
    }

    @Test
    func stereoSourceMapsToPreferredPairOfInterleavedSixChannelBuffer() {
        let written = mappedCopy(
            source: [1, 2, 3, 4],
            sourceChannelCount: 2,
            channelLayout: [6],
            frames: 2,
            pair: (2, 3)
        )

        #expect(written == [[
            0, 0, 1, 2, 0, 0,
            0, 0, 3, 4, 0, 0
        ]])
    }

    @Test
    func stereoSourceMapsIntoMiddleStreamOfMultiStreamLayout() {
        let written = mappedCopy(
            source: [1, 2, 3, 4],
            sourceChannelCount: 2,
            channelLayout: [2, 2, 2],
            frames: 2,
            pair: (2, 3)
        )

        #expect(written == [
            [0, 0, 0, 0],
            [1, 2, 3, 4],
            [0, 0, 0, 0]
        ])
    }

    @Test
    func stereoSourcePairCanSpanStreamBoundaries() {
        let written = mappedCopy(
            source: [1, 2, 3, 4],
            sourceChannelCount: 2,
            channelLayout: [2, 2, 2],
            frames: 2,
            pair: (1, 2)
        )

        #expect(written == [
            [0, 1, 0, 3],
            [2, 0, 4, 0],
            [0, 0, 0, 0]
        ])
    }

    @Test
    func monoSourceFeedsBothPairChannelsOnly() {
        let written = mappedCopy(
            source: [5, 6],
            sourceChannelCount: 1,
            channelLayout: [6],
            frames: 2,
            pair: (2, 3)
        )

        #expect(written == [[
            0, 0, 5, 5, 0, 0,
            0, 0, 6, 6, 0, 0
        ]])
    }

    @Test
    func pairBeyondDeviceBuffersProducesSilenceWithoutCrashing() {
        let written = mappedCopy(
            source: [1, 2, 3, 4],
            sourceChannelCount: 2,
            channelLayout: [2, 2],
            frames: 2,
            pair: (4, 5)
        )

        #expect(written == [
            [0, 0, 0, 0],
            [0, 0, 0, 0]
        ])
    }

    @Test
    func chunkedMappedWritesTileWithoutOverwritingEachOther() {
        let written = withMappedBuffers(channelLayout: [6], frames: 4) { buffers in
            let firstChunk: [Float] = [1, 2, 3, 4]
            let secondChunk: [Float] = [5, 6, 7, 8]
            firstChunk.withUnsafeBufferPointer { source in
                SystemTapAudioEngine.copyInterleavedSamples(
                    source,
                    sourceFrameOffset: 0,
                    destinationFrameOffset: 0,
                    frameCount: 2,
                    sourceChannelCount: 2,
                    destinationLeftChannel: 0,
                    destinationRightChannel: 1,
                    to: buffers
                )
            }
            secondChunk.withUnsafeBufferPointer { source in
                SystemTapAudioEngine.copyInterleavedSamples(
                    source,
                    sourceFrameOffset: 0,
                    destinationFrameOffset: 2,
                    frameCount: 2,
                    sourceChannelCount: 2,
                    destinationLeftChannel: 0,
                    destinationRightChannel: 1,
                    to: buffers
                )
            }
        }

        #expect(written == [[
            1, 2, 0, 0, 0, 0,
            3, 4, 0, 0, 0, 0,
            5, 6, 0, 0, 0, 0,
            7, 8, 0, 0, 0, 0
        ]])
    }

    @Test
    func reversedPairSwapsChannelsOnStereoDevice() {
        let written = mappedCopy(
            source: [1, 2, 3, 4],
            sourceChannelCount: 2,
            channelLayout: [2],
            frames: 2,
            pair: (1, 0)
        )

        #expect(written == [[2, 1, 4, 3]])
    }

    @Test
    func identityPairKeepsStereoFastPathBehavior() {
        let written = mappedCopy(
            source: [1, 2, 3, 4],
            sourceChannelCount: 2,
            channelLayout: [2],
            frames: 2,
            pair: (0, 1)
        )

        #expect(written == [[1, 2, 3, 4]])
    }

    // MARK: - Helpers

    /// Builds an AudioBufferList with one garbage-prefilled buffer per channelLayout entry,
    /// runs the body against it, and returns the resulting buffer contents.
    private func withMappedBuffers(
        channelLayout: [Int],
        frames: Int,
        prefill: Float = -1,
        _ body: (UnsafeMutableAudioBufferListPointer) -> Void
    ) -> [[Float]] {
        let storages = channelLayout.map { channels -> UnsafeMutableBufferPointer<Float> in
            let storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: channels * frames)
            storage.initialize(repeating: prefill)
            return storage
        }
        defer {
            for storage in storages {
                storage.deallocate()
            }
        }

        let bufferList = AudioBufferList.allocate(maximumBuffers: channelLayout.count)
        defer {
            free(bufferList.unsafeMutablePointer)
        }
        for (index, channels) in channelLayout.enumerated() {
            bufferList[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(channels * frames * MemoryLayout<Float>.stride),
                mData: UnsafeMutableRawPointer(storages[index].baseAddress)
            )
        }

        body(bufferList)

        return storages.map(Array.init)
    }

    private func mappedCopy(
        source: [Float],
        sourceChannelCount: Int,
        channelLayout: [Int],
        frames: Int,
        destinationFrameOffset: Int = 0,
        frameCount: Int? = nil,
        pair: (left: Int, right: Int) = (0, 1)
    ) -> [[Float]] {
        withMappedBuffers(channelLayout: channelLayout, frames: frames) { buffers in
            source.withUnsafeBufferPointer { sourcePointer in
                SystemTapAudioEngine.copyInterleavedSamples(
                    sourcePointer,
                    sourceFrameOffset: 0,
                    destinationFrameOffset: destinationFrameOffset,
                    frameCount: frameCount ?? frames,
                    sourceChannelCount: sourceChannelCount,
                    destinationLeftChannel: pair.left,
                    destinationRightChannel: pair.right,
                    to: buffers
                )
            }
        }
    }
}
