import Foundation

/// Plays one input's sound through one of the Mac's outputs. The app's backend uses AVFoundation; tests use a fake.
public protocol PassBackend: AnyObject {
    /// Starts playing the input with this ID to this output (nil: the Mac's default output) at this amplitude
    /// (0 to 1), replacing anything already playing.
    func start(inputID: String, outputID: String?, amplitude: Float) throws
    func stop()
    func setAmplitude(_ amplitude: Float)
}

public enum FlowState: Equatable {
    case stopped
    case flowing(AudioInput)
    /// The user wants sound, but the input (this name) is not connected. It starts by itself when it is.
    case waiting(String)
    /// Starting failed (the message says why). Picking an input or pressing start tries again.
    case failed(String)

    public var isOn: Bool { if case .stopped = self { return false }; return true }
}

/// Start, stop, pick an input and an output, set the volume, and follow devices coming and going.
public final class Passthrough {
    private let backend: PassBackend
    private let settings: PassSettings
    public private(set) var state: FlowState = .stopped
    public private(set) var inputs: [AudioInput] = []
    public private(set) var outputs: [AudioOutput] = []
    /// The output the sound is playing to right now (nil: the default output).
    private var activeOutputID: String?
    /// Called after every change of state, inputs or volume.
    public var onChange: (() -> Void)?

    public init(backend: PassBackend, settings: PassSettings) {
        self.backend = backend
        self.settings = settings
    }

    public var volumePercent: Int { settings.volumePercent }
    /// The input Nerdpass plays (or would play): the picked one if connected, else a capture card if none is picked.
    public var selected: AudioInput? {
        chooseInput(from: inputs, savedID: settings.inputID, savedName: settings.inputName)
    }
    /// The picked input's name, connected or not.
    public var selectedName: String? { selected?.name ?? settings.inputName }
    /// The output Nerdpass plays to: the picked one if connected, else nil (the Mac's default output).
    public var selectedOutput: AudioOutput? {
        chooseOutput(from: outputs, savedID: settings.outputID, savedName: settings.outputName)
    }

    public func start() { attempt() }

    public func stop() {
        backend.stop()
        state = .stopped
        onChange?()
    }

    public func toggle() { state.isOn ? stop() : start() }

    /// At quit.
    public func shutdown() { backend.stop() }

    /// At launch: starts the sound when always on is set.
    public func launch() { if settings.alwaysOn { attempt() } }

    public var alwaysOn: Bool { settings.alwaysOn }
    public func setAlwaysOn(_ on: Bool) {
        settings.alwaysOn = on
        onChange?()
    }

    /// Picks an input and starts passing it through.
    public func select(_ input: AudioInput) {
        settings.inputID = input.id
        settings.inputName = input.name
        start()
    }

    /// Picks where the sound goes (nil: the Mac's default output). Playing sound moves there right away.
    public func selectOutput(_ output: AudioOutput?) {
        settings.outputID = output?.id
        settings.outputName = output?.name
        if case .flowing = state { attempt() } else { onChange?() }
    }

    /// The outputs the Mac sees now. When the picked output disappears the sound moves to the default output,
    /// and it moves back when the picked output returns.
    public func updateOutputs(_ list: [AudioOutput]) {
        outputs = list
        if case .flowing = state, selectedOutput?.id != activeOutputID { attempt(); return }
        onChange?()
    }

    /// The Mac's default output changed (in Sound settings or Control Center). Sound playing to the default output
    /// follows it there.
    public func defaultOutputChanged() {
        if case .flowing = state, activeOutputID == nil { attempt() }
    }

    public func setVolume(_ percent: Int) {
        settings.volumePercent = percent
        backend.setAmplitude(amplitude(percent: settings.volumePercent))
        onChange?()
    }

    /// The inputs the Mac sees now. When the playing input disappears Nerdpass waits for it, and when a waited-for
    /// input (or, with nothing picked yet, a capture card) appears it starts.
    public func updateInputs(_ list: [AudioInput]) {
        inputs = list
        switch state {
        case let .flowing(input) where !list.contains(input):
            backend.stop()
            state = .waiting(settings.inputName ?? input.name)
        case .waiting:
            attempt()
            return
        default: break
        }
        onChange?()
    }

    /// Records that starting is impossible for a reason outside Nerdpass (microphone access denied).
    public func fail(_ message: String) {
        backend.stop()
        state = .failed(message)
        onChange?()
    }

    private func attempt() {
        guard let input = selected else {
            backend.stop()
            state = .waiting(settings.inputName ?? "a capture card")
            onChange?()
            return
        }
        do {
            let output = selectedOutput?.id
            try backend.start(inputID: input.id, outputID: output, amplitude: amplitude(percent: settings.volumePercent))
            activeOutputID = output
            settings.inputID = input.id
            settings.inputName = input.name
            state = .flowing(input)
        } catch {
            state = .failed("can't open \(input.name): \(error.localizedDescription)")
        }
        onChange?()
    }
}

/// The status line (the menu bar icon's tooltip). `output` is where the sound goes (nil: the default output).
public func statusLine(_ state: FlowState, output: String? = nil) -> String {
    switch state {
    case .stopped: return "stopped"
    case let .flowing(input): return "\(input.name) → \(output ?? "speakers")"
    case let .waiting(name): return "waiting for \(name)…"
    case let .failed(message): return message
    }
}
