import CoreAudio
import Foundation

/// Coordinates GlassEQ's own Core Audio device-property writes with the default-output observer
/// so the engine never reacts to changes it caused itself.
///
/// When the engine reconfigures the output device (writing buffer frame size or nominal sample
/// rate, including restores), the write produces an asynchronous property-change notification.
/// Our own DefaultOutputDeviceObserver listens for exactly those properties to detect
/// external format changes, so without coordination our write would trigger a rebuild loop.
///
/// The setter arms a short per-device suppression window immediately before writing.
/// The observer ignores buffer/rate/stream-format notifications for that device while the window
/// is open. Device-alive notifications are never suppressed.
/// External changes that happen to land inside the brief window are missed, which is
/// acceptable – they only occur right as we are reconfiguring the same device, and the user can
/// re-trigger them.
final class CoreAudioSelfChangeGuard: @unchecked Sendable {
    static let shared = CoreAudioSelfChangeGuard()

    private let lock = NSLock()
    private var suppressUntilByDevice: [AudioObjectID: UInt64] = [:]
    private let windowNanoseconds: UInt64

    init(windowMilliseconds: UInt64 = 750) {
        windowNanoseconds = windowMilliseconds * 1_000_000
    }

    /// Call immediately before writing a device property we control, so the resulting
    /// asynchronous property-change notification is recognized as self-induced.
    func beginSelfChange(deviceID: AudioObjectID) {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return
        }
        let until = DispatchTime.now().uptimeNanoseconds &+ windowNanoseconds
        lock.lock()
        suppressUntilByDevice[deviceID] = until
        lock.unlock()
    }

    /// Whether a property-change notification for this device falls inside an open self-change
    /// window and should therefore be ignored.
    func isSelfChange(deviceID: AudioObjectID) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        guard let until = suppressUntilByDevice[deviceID] else {
            return false
        }
        if now < until {
            return true
        }
        suppressUntilByDevice[deviceID] = nil
        return false
    }
}
