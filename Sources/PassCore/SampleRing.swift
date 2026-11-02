import Foundation
import os

/// A short buffer between the capture card and the output, which run on different clocks. Capture writes stereo
/// frames as they arrive; the output reads them on its own schedule. Playback starts once `target` frames are
/// waiting (about 20 ms), and the buffer never grows past `limit` (about 120 ms): when the card runs ahead of the
/// output the oldest frames are dropped back to `target`, so the delay stays short. When it runs dry it plays
/// silence and waits for `target` frames again.
public final class SampleRing: @unchecked Sendable {
    public let capacity: Int, target: Int, limit: Int
    private var left: [Float], right: [Float]
    private var readIndex = 0, count = 0, primed = false
    private let lock = OSAllocatedUnfairLock()
    /// Frames dropped to catch up, and times the output ran dry (for `--audio-check`).
    public private(set) var dropped = 0, underruns = 0

    public init(sampleRate: Double, target: Double = 0.02, limit: Double = 0.12) {
        capacity = Int(sampleRate)
        self.target = Int(sampleRate * target)
        self.limit = Int(sampleRate * limit)
        left = [Float](repeating: 0, count: capacity)
        right = [Float](repeating: 0, count: capacity)
    }

    /// Frames waiting to be played.
    public var fill: Int { lock.withLock { count } }

    /// Adds interleaved stereo frames.
    public func write(interleaved samples: UnsafePointer<Float>, frames: Int) {
        lock.withLockUnchecked {
            let n = min(frames, capacity)
            let skip = frames - n
            var write = (readIndex + count) % capacity
            for i in 0..<n {
                left[write] = samples[(skip + i) * 2]
                right[write] = samples[(skip + i) * 2 + 1]
                write = (write + 1) % capacity
            }
            count += n
            if count > capacity { readIndex = (readIndex + count - capacity) % capacity; count = capacity }
            if count > limit {
                let drop = count - target
                readIndex = (readIndex + drop) % capacity
                count -= drop
                dropped += drop
            }
        }
    }

    /// Fills the two channel buffers with `frames` frames, or silence for whatever isn't there.
    public func read(left outL: UnsafeMutablePointer<Float>, right outR: UnsafeMutablePointer<Float>, frames: Int) {
        lock.withLockUnchecked {
            if !primed {
                guard count >= target else {
                    outL.update(repeating: 0, count: frames); outR.update(repeating: 0, count: frames)
                    return
                }
                primed = true
            }
            let n = min(frames, count)
            for i in 0..<n {
                outL[i] = left[readIndex]; outR[i] = right[readIndex]
                readIndex = (readIndex + 1) % capacity
            }
            count -= n
            if n < frames {
                (outL + n).update(repeating: 0, count: frames - n)
                (outR + n).update(repeating: 0, count: frames - n)
                primed = false
                underruns += 1
            }
        }
    }

    public func reset() { lock.withLock { readIndex = 0; count = 0; primed = false } }
}
