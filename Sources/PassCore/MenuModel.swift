import Foundation

/// The menu, described without AppKit so its layout can be tested.
public enum MenuEntry: Equatable {
    /// The status line and the big start/stop button.
    case flow(status: String, on: Bool, enabled: Bool)
    case volume(percent: Int)
    /// A dim "// input" or "// output" label over a list.
    case header(String)
    case input(name: String, symbol: String, checked: Bool)
    case noInputs
    /// An output; `name` nil is the Mac's default output.
    case output(name: String?, symbol: String, checked: Bool)
    /// Microphone access was refused; clicking opens the Privacy settings.
    case permission
    case feedback
    /// Start the sound every time Nerdpass opens.
    case alwaysOn(on: Bool)
    case openAtLogin(on: Bool)
    case exit
    case separator
}

public struct MenuState {
    public var flow: FlowState
    public var inputs: [AudioInput]
    public var selectedID: String?
    public var outputs: [AudioOutput]
    /// The picked output if connected; nil plays to the default output.
    public var selectedOutputID: String?
    public var volumePercent: Int
    public var alwaysOn: Bool
    public var openAtLogin: Bool
    public var accessDenied: Bool
    public init(flow: FlowState, inputs: [AudioInput], selectedID: String?, outputs: [AudioOutput] = [],
                selectedOutputID: String? = nil, volumePercent: Int,
                alwaysOn: Bool, openAtLogin: Bool, accessDenied: Bool = false) {
        self.flow = flow; self.inputs = inputs; self.selectedID = selectedID
        self.outputs = outputs; self.selectedOutputID = selectedOutputID
        self.volumePercent = volumePercent; self.alwaysOn = alwaysOn; self.openAtLogin = openAtLogin
        self.accessDenied = accessDenied
    }
}

public let captureCardSymbol = "tv"
public let otherInputSymbol = "mic"

/// Start/stop and the volume first, then the inputs (capture cards before microphones), then the outputs (the
/// Mac's default first), then feedback, always on, open at login, and Exit last.
public func menuEntries(for s: MenuState) -> [MenuEntry] {
    var items: [MenuEntry] = [
        .flow(status: statusLine(s.flow, output: s.outputs.first { $0.id == s.selectedOutputID }?.name), on: s.flow.isOn, enabled: s.flow.isOn || !s.inputs.isEmpty),
        .volume(percent: s.volumePercent),
        .separator,
    ]
    if s.accessDenied { items.append(.permission) }
    items.append(.header("// input"))
    if s.inputs.isEmpty { items.append(.noInputs) }
    let cards = s.inputs.filter(\.looksLikeCaptureCard), others = s.inputs.filter { !$0.looksLikeCaptureCard }
    for input in cards + others {
        items.append(.input(name: input.name, symbol: input.looksLikeCaptureCard ? captureCardSymbol : otherInputSymbol,
                            checked: input.id == s.selectedID))
    }
    items.append(.header("// output"))
    items.append(.output(name: nil, symbol: "speaker.wave.2", checked: s.selectedOutputID == nil))
    for output in s.outputs {
        items.append(.output(name: output.name, symbol: outputSymbol(output.name), checked: output.id == s.selectedOutputID))
    }
    items.append(.separator)
    items.append(.feedback)
    items.append(.alwaysOn(on: s.alwaysOn))
    items.append(.openAtLogin(on: s.openAtLogin))
    items.append(.exit)
    return items
}
