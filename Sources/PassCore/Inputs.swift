import Foundation

/// Where to report bugs and ideas (the panel's feedback row).
public let feedbackURL = URL(string: "https://github.com/grumpitect/nerdpass/issues/new/choose")!
/// The project page (the panel title links to it).
public let projectURL = URL(string: "https://github.com/grumpitect/nerdpass")!
/// The YouTube channel Nerdpass was made for.
public let channelURL = URL(string: "https://www.youtube.com/@nerdative")!

/// An audio input the Mac can see: a capture card, a microphone, an audio interface...
public struct AudioInput: Equatable {
    /// The system's unique ID (stable while the device stays on the same port).
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }

    public var looksLikeCaptureCard: Bool { PassCore.looksLikeCaptureCard(name) }
}

/// Words in the names capture cards give their audio input (Elgato, AVerMedia, Magewell, generic USB dongles...).
public let captureCardKeywords = [
    "elgato", "game capture", "cam link", "hd60", "4k x", "4k60", "4k pro", "avermedia", "live gamer",
    "magewell", "usb capture", "ripsaw", "blackmagic", "ultrastudio", "capture", "hdmi", "video",
]

public func looksLikeCaptureCard(_ name: String) -> Bool {
    let n = name.lowercased()
    return captureCardKeywords.contains { n.contains($0) }
}

/// The input to pass through. The one the user picked comes first, matched by ID or, when its ID changed (it moved
/// to another port), by name. With nothing picked yet, the first input that looks like a capture card.
/// Returns nil when the picked input is not connected: Nerdpass then waits for it rather than switching to another
/// input, because playing a microphone through the speakers would howl.
public func chooseInput(from inputs: [AudioInput], savedID: String?, savedName: String?) -> AudioInput? {
    if savedID != nil || savedName != nil {
        return inputs.first { $0.id == savedID } ?? inputs.first { $0.name == savedName }
    }
    return inputs.first { $0.looksLikeCaptureCard }
}

/// Somewhere the sound can go: built-in speakers, headphones, a display, an audio interface...
public struct AudioOutput: Equatable {
    /// The system's unique ID (Core Audio's device UID).
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// The output to play to: the one the user picked (by ID, or by name when its ID changed), or nil for the Mac's
/// current default output, which is also where the sound goes while the picked output is disconnected.
public func chooseOutput(from outputs: [AudioOutput], savedID: String?, savedName: String?) -> AudioOutput? {
    guard savedID != nil || savedName != nil else { return nil }
    return outputs.first { $0.id == savedID } ?? outputs.first { $0.name == savedName }
}

/// An SF Symbol for an output, from its name.
public func outputSymbol(_ name: String) -> String {
    let n = name.lowercased()
    if ["headphone", "airpods", "earbuds", "buds", "headset", "beats"].contains(where: n.contains) { return "headphones" }
    if ["display", "hdmi", "tv", "monitor", "studio display"].contains(where: n.contains) { return "display" }
    return "hifispeaker"
}
