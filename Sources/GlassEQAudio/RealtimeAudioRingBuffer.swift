import Foundation
import Synchronization

struct RingBufferWriteResult: Equatable, Sendable {
    var writtenFrames: Int
    var droppedInputFrames: Int
    var droppedBufferedFrames: Int
}

public final class RealtimeAudioRingBuffer: @unchecked Sendable {
    public let channelCount: Int
    public let capacityFrames: Int

    private let storageFrameCapacity: Int
    private let storage: UnsafeMutableBufferPointer<Float>
    private let readFrame = Atomic<Int>(0)
    private let writeFrame = Atomic<Int>(0)
    private let overwriteGate = Atomic<Bool>(false)

    public init(channelCount: Int, capacityFrames: Int) {
        self.channelCount = max(channelCount, 1)
        self.capacityFrames = max(capacityFrames, 2)
        self.storageFrameCapacity = self.capacityFrames + 1
        self.storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: self.channelCount * self.storageFrameCapacity)
        self.storage.initialize(repeating: 0)
    }

    deinit {
        storage.deinitialize()
        storage.deallocate()
    }

    @discardableResult
    public func reset() -> Bool {
        guard enterOverwriteGate() else {
            return false
        }
        defer {
            leaveOverwriteGate()
        }
        let write = writeFrame.load(ordering: .acquiring)
        readFrame.store(write, ordering: .releasing)
        return true
    }

    public func write(_ frame: UnsafeBufferPointer<Float>) {
        writeInterleaved(frame, frameCount: 1, sourceChannelCount: frame.count)
    }

    public func read(into frame: UnsafeMutableBufferPointer<Float>) -> Bool {
        readInterleaved(into: frame, frameCount: 1, destinationChannelCount: frame.count) == 1
    }

    @discardableResult
    func writeInterleaved(
        _ samples: UnsafeBufferPointer<Float>,
        frameCount: Int,
        sourceChannelCount: Int
    ) -> RingBufferWriteResult {
        let sourceChannelCount = max(sourceChannelCount, 1)
        let requestedFrames = min(frameCount, samples.count / sourceChannelCount)
        guard requestedFrames > 0 else {
            return RingBufferWriteResult(writtenFrames: 0, droppedInputFrames: 0, droppedBufferedFrames: 0)
        }

        let framesToWrite = min(requestedFrames, capacityFrames)
        let firstSourceFrame = requestedFrames - framesToWrite

        let read = readFrame.load(ordering: .acquiring)
        let write = writeFrame.load(ordering: .relaxed)
        let retainedFrames = max(0, capacityFrames - framesToWrite)
        let droppedFrames = max(0, occupancyFrames(read: read, write: write) - retainedFrames)
        if droppedFrames > 0 {
            guard enterOverwriteGate() else {
                return RingBufferWriteResult(
                    writtenFrames: 0,
                    droppedInputFrames: requestedFrames,
                    droppedBufferedFrames: 0
                )
            }
            defer {
                leaveOverwriteGate()
            }
            readFrame.store(advance(read, by: droppedFrames), ordering: .releasing)
        }

        if sourceChannelCount == channelCount,
           let source = samples.baseAddress,
           let destination = storage.baseAddress {
            copyMatchingChannels(
                source: source.advanced(by: firstSourceFrame * channelCount),
                destination: destination,
                storageFrame: write,
                frameCount: framesToWrite
            )
        } else {
            var storageFrame = write
            for frameOffset in 0..<framesToWrite {
                let sourceBase = (firstSourceFrame + frameOffset) * sourceChannelCount
                let storageBase = storageFrame * channelCount
                for channel in 0..<channelCount {
                    storage[storageBase + channel] = samples[sourceBase + min(channel, sourceChannelCount - 1)]
                }
                storageFrame = advance(storageFrame)
            }
        }

        writeFrame.store(advance(write, by: framesToWrite), ordering: .releasing)
        return RingBufferWriteResult(
            writtenFrames: framesToWrite,
            droppedInputFrames: firstSourceFrame,
            droppedBufferedFrames: droppedFrames
        )
    }

    func readInterleaved(
        into samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        destinationChannelCount: Int
    ) -> Int {
        let destinationChannelCount = max(destinationChannelCount, 1)
        let requestedFrames = min(frameCount, samples.count / destinationChannelCount)
        guard requestedFrames > 0 else {
            return 0
        }

        let read = readFrame.load(ordering: .relaxed)
        let write = writeFrame.load(ordering: .acquiring)
        let framesToRead = min(requestedFrames, occupancyFrames(read: read, write: write))

        guard enterOverwriteGate() else {
            zeroFill(samples, startFrame: 0, frameCount: requestedFrames, channelCount: destinationChannelCount)
            return 0
        }
        defer {
            leaveOverwriteGate()
        }

        if destinationChannelCount == channelCount,
           let source = storage.baseAddress,
           let destination = samples.baseAddress {
            copyMatchingChannels(
                source: source,
                destination: destination,
                storageFrame: read,
                frameCount: framesToRead
            )
        } else {
            var storageFrame = read
            for frameOffset in 0..<framesToRead {
                let destinationBase = frameOffset * destinationChannelCount
                let storageBase = storageFrame * channelCount
                for channel in 0..<destinationChannelCount {
                    samples[destinationBase + channel] = storage[storageBase + min(channel, channelCount - 1)]
                }
                storageFrame = advance(storageFrame)
            }
        }

        if framesToRead < requestedFrames {
            zeroFill(
                samples,
                startFrame: framesToRead,
                frameCount: requestedFrames - framesToRead,
                channelCount: destinationChannelCount
            )
        }

        readFrame.store(advance(read, by: framesToRead), ordering: .releasing)
        return framesToRead
    }

    public func occupancyFrames() -> Int {
        let read = readFrame.load(ordering: .acquiring)
        let write = writeFrame.load(ordering: .acquiring)
        return occupancyFrames(read: read, write: write)
    }

    @discardableResult
    func trimToLatestFrames(_ frames: Int) -> Bool {
        guard enterOverwriteGate() else {
            return false
        }
        defer {
            leaveOverwriteGate()
        }

        let targetFrames = min(max(frames, 0), capacityFrames)
        let read = readFrame.load(ordering: .acquiring)
        let write = writeFrame.load(ordering: .acquiring)
        let occupancy = occupancyFrames(read: read, write: write)
        guard occupancy > targetFrames else {
            return true
        }

        readFrame.store(advance(read, by: occupancy - targetFrames), ordering: .releasing)
        return true
    }

    private func occupancyFrames(read: Int, write: Int) -> Int {
        if write >= read {
            return write - read
        }
        return storageFrameCapacity - read + write
    }

    private func advance(_ frame: Int) -> Int {
        let next = frame + 1
        return next == storageFrameCapacity ? 0 : next
    }

    private func advance(_ frame: Int, by distance: Int) -> Int {
        (frame + distance) % storageFrameCapacity
    }

    private func enterOverwriteGate() -> Bool {
        overwriteGate.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged
    }

    private func leaveOverwriteGate() {
        overwriteGate.store(false, ordering: .releasing)
    }

    private func copyMatchingChannels(
        source: UnsafePointer<Float>,
        destination: UnsafeMutablePointer<Float>,
        storageFrame: Int,
        frameCount: Int
    ) {
        guard frameCount > 0 else {
            return
        }

        let firstFrameCount = min(frameCount, storageFrameCapacity - storageFrame)
        let firstSampleCount = firstFrameCount * channelCount
        destination
            .advanced(by: storageFrame * channelCount)
            .update(from: source, count: firstSampleCount)

        let remainingFrames = frameCount - firstFrameCount
        guard remainingFrames > 0 else {
            return
        }

        destination.update(
            from: source.advanced(by: firstSampleCount),
            count: remainingFrames * channelCount
        )
    }

    private func copyMatchingChannels(
        source: UnsafeMutablePointer<Float>,
        destination: UnsafeMutablePointer<Float>,
        storageFrame: Int,
        frameCount: Int
    ) {
        copyMatchingChannels(
            source: UnsafePointer(source).advanced(by: storageFrame * channelCount),
            destination: destination,
            storageFrame: 0,
            frameCount: min(frameCount, storageFrameCapacity - storageFrame)
        )

        let firstFrameCount = min(frameCount, storageFrameCapacity - storageFrame)
        let remainingFrames = frameCount - firstFrameCount
        guard remainingFrames > 0 else {
            return
        }

        destination
            .advanced(by: firstFrameCount * channelCount)
            .update(from: source, count: remainingFrames * channelCount)
    }

    private func zeroFill(
        _ samples: UnsafeMutableBufferPointer<Float>,
        startFrame: Int,
        frameCount: Int,
        channelCount: Int
    ) {
        guard frameCount > 0 else {
            return
        }
        samples.baseAddress?
            .advanced(by: startFrame * channelCount)
            .initialize(repeating: 0, count: frameCount * channelCount)
    }
}
