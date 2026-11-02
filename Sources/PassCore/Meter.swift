import Foundation

/// Where the needle points for a sound level, on the meter's -20 to +3 VU scale: 0 is the left stop, 1 is +3 VU.
/// 0 VU is -18 dBFS (the usual digital alignment) and -15 dBFS pins it at +3. Above `meterKnee` the scale is a real
/// VU scale; below it the quiet end is stretched down to `meterFloor`, so quiet game audio still moves the needle.
public let meterKnee = -24.0
public let meterFloor = -60.0

public func needleTarget(rmsDecibels db: Float) -> Double {
    let d = Double(db)
    let vu = { (d: Double) in min(1.08, max(0, (d + 18 + 20) / 23)) }
    if d >= meterKnee { return vu(d) }
    return max(0, (d - meterFloor) / (meterKnee - meterFloor)) * vu(meterKnee)
}

/// Where the red zone starts on the scale (0 VU).
public let needleRedZone = 20.0 / 23.0

/// RMS level of float samples in dBFS (-120 for silence).
public func rmsDecibels(_ samples: UnsafeBufferPointer<Float>) -> Float {
    guard !samples.isEmpty else { return -120 }
    var sum: Float = 0
    for s in samples { sum += s * s }
    let rms = (sum / Float(samples.count)).squareRoot()
    return rms > 0 ? max(-120, 20 * log10(rms)) : -120
}

/// A damped spring, like a moving-coil meter: about 300 ms to reach a new level.
public struct NeedleBallistics: Equatable {
    public var position: Double = 0
    public var velocity: Double = 0
    public init() {}

    /// Moves toward `target` over `dt` seconds. A lower `damping` overshoots more (1 is critically damped).
    /// The needle can't go below its left stop: it bounces off it once, softly.
    public mutating func step(toward target: Double, dt: Double, damping: Double = 0.9, response: Double = 0.3) {
        let omega = 2 * Double.pi / response
        var left = dt
        while left > 0 {
            let h = min(left, 1.0 / 240)
            velocity += (omega * omega * (target - position) - 2 * damping * omega * velocity) * h
            position += velocity * h
            if position < 0 { position = 0; velocity = -velocity * 0.3 }
            left -= h
        }
    }

    public var isAtRest: Bool { position < 0.002 && abs(velocity) < 0.01 }
}

/// Everything that moves in the meter: the needle, the backlight warming up and fading, and the self-test sweep
/// while Nerdpass waits for the card. The app steps it about 30 times a second and draws from it.
public struct MeterAnimator {
    public enum Mode: Equatable { case off, flowing, waiting }
    public private(set) var mode: Mode = .off
    public private(set) var needle = NeedleBallistics()
    /// 0 (dark) to 1 (fully lit).
    public private(set) var backlight: Double = 0
    /// Seconds since the mode last changed.
    public private(set) var elapsed: Double = 0
    private var fadeFrom: Double = 0

    public static let warmUp = 0.7
    public static let kick = 0.35
    public static let fadeOut = 0.4
    public static let sweepPeriod = 3.0
    /// How quickly the needle follows sound getting louder, and quieter (seconds).
    public static let attack = 0.1
    public static let release = 0.6

    public init() {}

    public mutating func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        elapsed = 0
        fadeFrom = backlight
    }

    /// `level` is the needle target from the measured sound (0 to about 1).
    public mutating func step(dt: Double, level: Double) {
        elapsed += dt
        switch mode {
        case .flowing:
            backlight = Self.warmUpCurve(elapsed)
            // Starting kicks the needle to +3 first, then it settles onto the sound. It jumps up with the sound
            // (with a little overshoot) and falls back slowly, so hits feel immediate and fades linger.
            let target = elapsed < Self.kick ? 1.0 : level
            let rising = target > needle.position
            needle.step(toward: target, dt: dt, damping: rising ? 0.8 : 1.0, response: rising ? Self.attack : Self.release)
        case .waiting:
            backlight = min(1, elapsed / 0.3)
            let sweep = 0.5 - 0.5 * cos(2 * Double.pi * elapsed / Self.sweepPeriod)
            needle.step(toward: sweep, dt: dt)
        case .off:
            backlight = max(0, fadeFrom * (1 - elapsed / Self.fadeOut))
            needle.step(toward: 0, dt: dt, damping: 0.55)
        }
    }

    /// A lamp warming up: two quick dips in the first 200 ms, then a smooth rise to full over 700 ms.
    public static func warmUpCurve(_ t: Double) -> Double {
        if t >= warmUp { return 1 }
        let base = 0.15 + 0.85 * (t / warmUp)
        if (0.06..<0.10).contains(t) || (0.16..<0.20).contains(t) { return base * 0.7 }
        return base
    }

    /// Nothing left to animate: the icon can hold still.
    public var isIdle: Bool { mode == .off && backlight == 0 && needle.isAtRest }
}
