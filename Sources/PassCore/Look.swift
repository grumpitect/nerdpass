import Foundation

/// Nerdpass's four looks, in the picker's order. Each has its own colors, panel, volume control, menu bar icon and
/// animations.
public enum Look: String, CaseIterable, Equatable {
    /// From the app icon: a glowing cyan-to-blue wave on deep navy (the default).
    case burst
    /// A backlit analog VU meter on a walnut hi-fi faceplate.
    case needle
    /// An oscilloscope: a green phosphor trace on a dark CRT.
    case phosphor
    /// A broadcast switcher: red tally light when the card is on air.
    case tally
}

/// The start/stop button's label. Tally uses a switcher's verbs: take() puts the card on air, cut() takes it off.
public func flowButtonLabel(look: Look, on: Bool) -> String {
    switch look {
    case .tally: return on ? "cut()" : "take()"
    case .needle, .phosphor, .burst: return on ? "stop()" : "start()"
    }
}

/// An on-air clock: "00:12:44".
public func clockString(_ seconds: Int) -> String {
    let s = max(0, seconds)
    return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
}

/// The volume slider's percent for a gain in dB (the inverse of `amplitude(percent:)`: cubic up to 0 dB at 100%,
/// then linear, so +6 dB is 200%). Tally labels its fader in dB.
public func volumePercent(forDecibels db: Double) -> Double {
    db <= 0 ? pow(10, db / 60) * 100 : pow(10, db / 20) * 100
}
