import Foundation

/// What Nerdpass remembers between launches (in its UserDefaults).
public final class PassSettings {
    public static let defaultPercent = 80
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The volume slider, 0 to 100 (80 by default; 100 is the capture card's own level).
    public var volumePercent: Int {
        get { defaults.object(forKey: "volumePercent") == nil ? Self.defaultPercent : defaults.integer(forKey: "volumePercent") }
        set { defaults.set(min(100, max(0, newValue)), forKey: "volumePercent") }
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
    /// The look (needle by default).
    public var look: Look {
        get { defaults.string(forKey: "look").flatMap(Look.init(rawValue:)) ?? .needle }
        set { defaults.set(newValue.rawValue, forKey: "look") }
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

/// The slider follows VLC's cubic volume curve (like Nerdwave), so 50% sounds about half as loud.
/// 100% passes the capture card's sound through unchanged.
public func amplitude(percent: Int) -> Float {
    let p = Double(min(100, max(0, percent))) / 100
    return Float(pow(p, 3))
}
