import Foundation

/// What Nerdpass remembers between launches (in its UserDefaults).
public final class PassSettings {
    public static let defaultPercent = 100
    /// Up to 200%: past 100% Nerdpass boosts the card's sound (2x at 200%).
    public static let maxPercent = 200
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The volume slider, 0 to 200 (100 by default: the capture card's own level; above it is a boost).
    public var volumePercent: Int {
        get { defaults.object(forKey: "volumePercent") == nil ? Self.defaultPercent : defaults.integer(forKey: "volumePercent") }
        set { defaults.set(min(Self.maxPercent, max(0, newValue)), forKey: "volumePercent") }
    }
    /// The input the user picked (ID and name, so it is found again after moving to another port).
    public var inputID: String? {
        get { defaults.string(forKey: "inputID") }
        set { defaults.set(newValue, forKey: "inputID") }
    }
    public var inputName: String? {
        get { defaults.string(forKey: "inputName") }
        set { defaults.set(newValue, forKey: "inputName") }
    }
    /// The output the user picked; nil plays to the Mac's default output.
    public var outputID: String? {
        get { defaults.string(forKey: "outputID") }
        set { defaults.set(newValue, forKey: "outputID") }
    }
    public var outputName: String? {
        get { defaults.string(forKey: "outputName") }
        set { defaults.set(newValue, forKey: "outputName") }
    }
    /// The look (burst by default).
    public var look: Look {
        get { defaults.string(forKey: "look").flatMap(Look.init(rawValue:)) ?? .burst }
        set { defaults.set(newValue.rawValue, forKey: "look") }
    }
    /// Shift + the volume keys control Nerdpass's volume (on by default; needs Accessibility access).
    public var volumeKeys: Bool {
        get { defaults.object(forKey: "volumeKeys") == nil ? true : defaults.bool(forKey: "volumeKeys") }
        set { defaults.set(newValue, forKey: "volumeKeys") }
    }
    /// Always on: Nerdpass starts the sound every time it opens (on by default).
    public var alwaysOn: Bool {
        get { defaults.object(forKey: "alwaysOn") == nil ? true : defaults.bool(forKey: "alwaysOn") }
        set { defaults.set(newValue, forKey: "alwaysOn") }
    }
    /// Whether Nerdpass already turned on open at login by itself (it does once, at first launch, so turning it
    /// off later sticks).
    public var didDefaultLogin: Bool {
        get { defaults.bool(forKey: "didDefaultLogin") }
        set { defaults.set(newValue, forKey: "didDefaultLogin") }
    }
}

/// The volume slider to a gain. Up to 100% it follows VLC's cubic curve (like Nerdwave), so 50% sounds about half as
/// loud and 100% passes the card's sound through unchanged. Above 100% the percent is the multiplier, like Nerdfader
/// and other boosters: 200% is 2x (+6 dB).
public func amplitude(percent: Int) -> Float {
    let p = Double(min(PassSettings.maxPercent, max(0, percent)))
    return Float(p <= 100 ? pow(p / 100, 3) : p / 100)
}

/// Nerdfader's soft clipper: unchanged below 60% of full scale, then peaks are rounded off below a 97% ceiling, so
/// a boost never clips harshly.
public func softClip(_ x: Float) -> Float {
    let knee: Float = 0.6, ceiling: Float = 0.97, a = abs(x)
    guard a > knee else { return x }
    let rounded = knee + (ceiling - knee) * tanh((a - knee) / (ceiling - knee))
    return x < 0 ? -rounded : rounded
}
