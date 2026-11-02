// Nerdpass: plays a capture card's sound through the Mac, from the menu bar (AppKit + SwiftUI glue around PassCore).
import AppKit
import AVFoundation
import CoreAudio
import PassCore
import ServiceManagement
import SwiftUI

// MARK: - Audio

/// Every audio input the Mac sees (capture cards, microphones, interfaces).
func listInputs() -> [AudioInput] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        .devices.map { AudioInput(id: $0.uniqueID, name: $0.localizedName) }
}

/// Every output the Mac can play to (speakers, headphones, displays, interfaces), from Core Audio.
func listOutputs() -> [AudioOutput] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return AudioOutput(id: uid, name: name)
    }
}

private func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String
}

/// Calls back on the main queue when the Mac's audio devices or its default output change.
func watchAudioDevices(devicesChanged: @escaping () -> Void, defaultChanged: @escaping () -> Void) {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var devices = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectAddPropertyListenerBlock(system, &devices, .main) { _, _ in devicesChanged() }
    var output = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectAddPropertyListenerBlock(system, &output, .main) { _, _ in defaultChanged() }
}

struct PassError: LocalizedError {
    let errorDescription: String?
}

/// Receives the card's sound from the capture session (as 48 kHz stereo floats), passes it to the output buffer,
/// and measures its level for the meter. Runs on the capture queue.
final class CaptureTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let ring: SampleRing
    private let lock = NSLock()
    private var latest: Float = -120
    private var peak: Float?
    /// Frames received (for `--audio-check`).
    private(set) var framesIn = 0

    init(ring: SampleRing) { self.ring = ring }

    /// The loudest buffer's RMS level in dBFS since the last call, so a short hit between two frames still
    /// shows. With no new buffer since then, the last level again.
    func take() -> Float {
        lock.lock(); defer { lock.unlock() }
        if let p = peak { latest = p; peak = nil }
        return latest
    }

    func reset() {
        lock.lock(); latest = -120; peak = nil; lock.unlock()
        ring.reset()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        var loudest: Float = -120
        try? sampleBuffer.withAudioBufferList { list, _ in
            // The data output converts to interleaved stereo floats (see `CaptureBackend.start`): one buffer.
            guard let buffer = list.first, let data = buffer.mData, buffer.mNumberChannels == 2 else { return }
            let samples = data.assumingMemoryBound(to: Float.self), count = Int(buffer.mDataByteSize) / 4
            ring.write(interleaved: samples, frames: count / 2)
            loudest = rmsDecibels(UnsafeBufferPointer(start: samples, count: count))
            framesIn += count / 2
        }
        lock.lock(); peak = max(peak ?? -120, loudest); lock.unlock()
    }
}

/// The volume the output applies, set from the main thread and read on the audio thread.
final class GainControl: @unchecked Sendable {
    var target: Float = 1
}

/// The Core Audio device ID for a device UID, or nil.
func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString, id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafePointer(to: &cfUID) {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                   UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
    }
    return status == noErr && id != 0 ? id : nil
}

/// Plays an input live through one of the Mac's outputs and measures its level for the meter. The card's sound goes
/// capture session -> a short buffer -> gain -> Nerdfader's soft clipper -> the output, so the volume can go past
/// 100% (up to 2x at 200%) without clipping harshly.
final class CaptureBackend: PassBackend {
    static let sampleRate = 48_000.0
    let ring = SampleRing(sampleRate: CaptureBackend.sampleRate)
    lazy var levels = CaptureTap(ring: ring)
    let gain = GainControl()
    private var session: AVCaptureSession?
    private var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []
    private let tapQueue = DispatchQueue(label: "nerdpass.capture", qos: .userInteractive)
    /// startRunning and stopRunning block, so they run off the main thread, in order.
    private let queue = DispatchQueue(label: "nerdpass.session")
    /// Called on the main thread when the sound stops for a reason outside Nerdpass (the card in use elsewhere).
    var onError: ((String) -> Void)?
    /// Frames the output has played (for `--audio-check`).
    private(set) var framesOut = 0

    func start(inputID: String, outputID: String?, amplitude: Float) throws {
        stop()
        guard let device = AVCaptureDevice(uniqueID: inputID) else { throw PassError(errorDescription: "not connected") }
        gain.target = amplitude

        let engine = AVAudioEngine()
        if let outputID, var id = audioDeviceID(forUID: outputID), let unit = engine.outputNode.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)!
        let ring = ring, gain = gain
        var current = amplitude
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let frames = Int(frameCount)
            ring.read(left: l, right: r, frames: frames)
            // Glide to the set volume over about 20 ms, so moving the slider never clicks.
            let target = gain.target
            for i in 0..<frames {
                current += (target - current) * 0.001
                l[i] = softClip(l[i] * current)
                r[i] = softClip(r[i] * current)
            }
            self?.framesOut += frames
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate,
                                AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
        output.setSampleBufferDelegate(levels, queue: tapQueue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            engine.stop()
            throw PassError(errorDescription: "can't route its sound")
        }
        session.addInput(input)
        session.addOutput(output)
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                                object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onError?("audio stopped: \(error?.localizedDescription ?? "unknown error")")
        })
        // The output's format changed (sample rate, device): Core Audio stops the engine; start it again.
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak engine] _ in
            guard let engine, !engine.isRunning else { return }
            try? engine.start()
        })
        self.engine = engine
        self.session = session
        queue.async { session.startRunning() }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let s = session { queue.async { s.stopRunning() } }
        session = nil
        engine?.stop()
        engine = nil
        levels.reset()
    }

    func setAmplitude(_ amplitude: Float) { gain.target = amplitude }
}

/// Makes no sound: for `--snapshot --demo`.
final class SilentBackend: PassBackend {
    func start(inputID: String, outputID: String?, amplitude: Float) throws {}
    func stop() {}
    func setAmplitude(_ amplitude: Float) {}
}

/// Shared state for the panel, refreshed whenever the passthrough changes.
final class AppModel: ObservableObject {
    let pass: Passthrough
    @Published var entries: [MenuEntry] = []
    @Published var volumePercent: Int
    @Published var isFlowing = false
    @Published var isWaiting = false
    @Published var look: Look = .needle
    /// When the sound started flowing (Tally's on-air clock).
    var flowStartedAt: Date?
    var onQuit: (() -> Void)?
    /// Closes the menu panel (used after opening a link).
    var closePanel: (() -> Void)?
    /// Called after every refresh (the menu bar icon follows the state).
    var onRefresh: (() -> Void)?

    let settings: PassSettings
    /// The needle and backlight (stepped by the app delegate, drawn by the panel and the menu bar icon).
    var meter = MeterAnimator()
    /// The current sound level in dBFS.
    var levelDecibels: () -> Float

    init(backend: PassBackend = CaptureBackend(), settings: PassSettings = PassSettings()) {
        self.settings = settings
        let tap = (backend as? CaptureBackend)?.levels
        levelDecibels = { tap?.take() ?? -22 }
        pass = Passthrough(backend: backend, settings: settings)
        volumePercent = pass.volumePercent
        pass.onChange = { [weak self] in self?.refresh() }
        (backend as? CaptureBackend)?.onError = { [weak self] in self?.pass.fail($0) }
    }

    /// Set by `--snapshot --demo --denied` to show the permission row without changing the real permission.
    var showDenied = false
    var accessDenied: Bool {
        if showDenied { return true }
        let s = AVCaptureDevice.authorizationStatus(for: .audio)
        return s == .denied || s == .restricted
    }

    func refresh() {
        volumePercent = pass.volumePercent
        look = pass.look
        if case .flowing = pass.state { isFlowing = true } else { isFlowing = false }
        if isFlowing, flowStartedAt == nil { flowStartedAt = Date() } else if !isFlowing { flowStartedAt = nil }
        if case .waiting = pass.state { isWaiting = true } else { isWaiting = false }
        entries = menuEntries(for: MenuState(
            flow: pass.state, inputs: pass.inputs, selectedID: pass.selected?.id,
            outputs: pass.outputs, selectedOutputID: pass.selectedOutput?.id, volumePercent: volumePercent, look: look,
            alwaysOn: pass.alwaysOn, openAtLogin: SMAppService.mainApp.status == .enabled, accessDenied: accessDenied))
        onRefresh?()
    }

    /// macOS treats a capture card's sound like a microphone, so Nerdpass asks for that access once.
    private func withAccess(_ then: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: then()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { then() } else { self?.pass.fail("no access to audio inputs") }
                }
            }
        default: pass.fail("no access to audio inputs")
        }
    }

    func toggle() {
        if pass.state.isOn { pass.stop() } else { withAccess { [weak self] in self?.pass.start() } }
    }
    func start() { withAccess { [weak self] in self?.pass.start() } }
    func select(_ name: String) {
        guard let input = pass.inputs.first(where: { $0.name == name }) else { return }
        withAccess { [weak self] in self?.pass.select(input) }
    }
    func launch() { if pass.alwaysOn { withAccess { [weak self] in self?.pass.launch() } } }
    func toggleAlwaysOn() { pass.setAlwaysOn(!pass.alwaysOn) }
    func setLook(_ look: Look) { pass.setLook(look) }

    /// Open at login is on by default: Nerdpass turns it on once, at its first launch, so turning it off sticks.
    func defaultLoginOnce() {
        guard !settings.didDefaultLogin else { return }
        settings.didDefaultLogin = true
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
    }
    func setVolume(_ p: Int) { pass.setVolume(p) }

    /// Follows the passthrough state and advances the needle by `dt` seconds.
    func stepMeter(_ dt: Double) {
        meter.setMode(isFlowing ? .flowing : (isWaiting ? .waiting : .off))
        meter.step(dt: dt, level: needleTarget(rmsDecibels: levelDecibels()))
    }
    func inputsChanged() { pass.updateInputs(listInputs()) }
    func outputsChanged() { pass.updateOutputs(listOutputs()) }
    /// `name` nil picks the Mac's default output.
    func selectOutput(_ name: String?) {
        pass.selectOutput(name.flatMap { n in pass.outputs.first { $0.name == n } })
    }

    func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        else { try? SMAppService.mainApp.register() }
        refresh()
    }

    /// Opens a link in the browser and closes the panel.
    func open(_ url: URL) {
        closePanel?()
        NSWorkspace.shared.open(url)
    }
    func openFeedback() { open(feedbackURL) }
    func openPrivacySettings() {
        open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

// MARK: - Looks

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// One look's colors and shapes. Needle: walnut and a backlit orange meter. Phosphor: green trace on a dark CRT.
/// Tally: warm graphite with an on-air red, a ready green and a standby amber.
struct Palette {
    let look: Look
    let bg: Color, surface: Color, text: Color, dim: Color
    /// The main color (backlight orange, phosphor green, on-air red) and the second one (needle red, trace-head lime,
    /// ready green).
    let accent: Color, accent2: Color
    let waiting: Color
    let bezel: Color, line: Color
    let title: Color
    /// The name of a chosen input or output.
    let checkedText: Color
    let hover: Color
    let radius: CGFloat
    let accentNS: NSColor, accent2NS: NSColor, waitingNS: NSColor
    /// Menu bar ink that isn't tinted by macOS, on a dark and a light menu bar.
    let inkDarkBarNS: NSColor, inkLightBarNS: NSColor
    let font = Font.system(size: 13, design: .monospaced)
    /// The volume percent's color while boosting past 100%.
    var boost: Color { look == .tally ? waiting : accent2 }

    static let needle = Palette(
        look: .needle, bg: Color(hex: 0x16120C), surface: Color(hex: 0x221B12), text: Color(hex: 0xF4E9D4),
        dim: Color(hex: 0xA08E70), accent: Color(hex: 0xFF9F1C), accent2: Color(hex: 0xE8452C), waiting: Color(hex: 0x6CB4FF),
        bezel: Color(hex: 0x3A2E1E), line: Color(hex: 0x2E2418), title: Color(hex: 0xFF9F1C), checkedText: Color(hex: 0xFF9F1C),
        hover: Color(hex: 0xFF9F1C, alpha: 0.10), radius: 14,
        accentNS: NSColor(hex: 0xFF9F1C), accent2NS: NSColor(hex: 0xE8452C), waitingNS: NSColor(hex: 0x6CB4FF),
        inkDarkBarNS: NSColor(hex: 0xF4E9D4), inkLightBarNS: NSColor(hex: 0x3A2A12))
    static let phosphor = Palette(
        look: .phosphor, bg: Color(hex: 0x07110C), surface: Color(hex: 0x0E1D15), text: Color(hex: 0xD8F5E3),
        dim: Color(hex: 0x6E9A80), accent: Color(hex: 0x3DFF8A), accent2: Color(hex: 0xB6FF5C), waiting: Color(hex: 0xFFB547),
        bezel: Color(hex: 0x1F4A31), line: Color(hex: 0x3DFF8A, alpha: 0.25), title: Color(hex: 0x3DFF8A),
        checkedText: Color(hex: 0x3DFF8A), hover: Color(hex: 0x3DFF8A, alpha: 0.08), radius: 7,
        accentNS: NSColor(hex: 0x3DFF8A), accent2NS: NSColor(hex: 0xB6FF5C), waitingNS: NSColor(hex: 0xFFB547),
        inkDarkBarNS: NSColor(hex: 0x3DFF8A), inkLightBarNS: NSColor(hex: 0x11A852))
    static let tally = Palette(
        look: .tally, bg: Color(hex: 0x141113), surface: Color(hex: 0x1F1A1C), text: Color(hex: 0xF2ECE4),
        dim: Color(hex: 0x9A8F88), accent: Color(hex: 0xFF4A3D), accent2: Color(hex: 0x3DDC84), waiting: Color(hex: 0xFFB020),
        bezel: Color(hex: 0x2E282A), line: Color(hex: 0x2A2426), title: Color(hex: 0xF2ECE4), checkedText: Color(hex: 0xF2ECE4),
        hover: Color(hex: 0xF2ECE4, alpha: 0.06), radius: 10,
        accentNS: NSColor(hex: 0xFF4A3D), accent2NS: NSColor(hex: 0x3DDC84), waitingNS: NSColor(hex: 0xFFB020),
        inkDarkBarNS: NSColor(hex: 0xF2ECE4), inkLightBarNS: NSColor(hex: 0x1B1B1D))

    static func of(_ look: Look) -> Palette {
        switch look {
        case .needle: return .needle
        case .phosphor: return .phosphor
        case .tally: return .tally
        }
    }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette.needle }
extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - Shared panel pieces

/// A row that lights up on hover (Phosphor also draws a bar at its left edge, like a scope's cursor).
struct RowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hover = false
    @Environment(\.palette) private var p
    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover ? p.hover : .clear))
                .overlay(alignment: .leading) {
                    if hover && p.look == .phosphor { Rectangle().fill(p.accent).frame(width: 2).padding(.vertical, 2) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover = $0 }
    }
}

/// Moves the label down a point while pressed, like a switch.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.offset(y: configuration.isPressed ? 1 : 0)
    }
}

/// The start/stop button, drawn per look: Needle's rocker with a pilot light, Phosphor's outlined key with a
/// glowing underline while on, Tally's green take() and solid red cut().
struct FlowButton: View {
    let on: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false
    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) { label.contentShape(Rectangle()) }
            .buttonStyle(PressStyle())
            .focusable(false)
            .disabled(!enabled)
            .help(on ? "Stop the sound" : "Play the capture card's sound through this Mac")
            .onHover { hover = $0 }
    }

    private var title: String { flowButtonLabel(look: p.look, on: on) }

    @ViewBuilder private var label: some View {
        switch p.look {
        case .needle:
            HStack(spacing: 8) {
                Circle().fill(on ? p.accent : p.bezel).frame(width: 6, height: 6).shadow(color: on ? p.accent : .clear, radius: 3)
                Text(title).bold()
            }
            .frame(width: 130, height: 30)
            .foregroundColor(enabled ? (hover ? p.bg : p.text) : p.dim.opacity(0.6))
            .background(RoundedRectangle(cornerRadius: 8).fill(hover && enabled ? p.accent : p.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(enabled ? p.accent : p.bezel))
        case .phosphor:
            HStack(spacing: 8) {
                Image(systemName: on ? "stop.fill" : "play.fill").font(.system(size: 11, weight: .bold))
                Text(title).bold()
                    .overlay(alignment: .bottom) {
                        if on && !hover {
                            Rectangle().fill(p.accent).frame(height: 2).offset(y: 4).shadow(color: p.accent, radius: 3)
                        }
                    }
            }
            .frame(width: 130, height: 30)
            .foregroundColor(enabled ? (hover ? p.bg : p.accent) : p.dim.opacity(0.6))
            .background(RoundedRectangle(cornerRadius: 4).fill(hover && enabled ? p.accent : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(enabled ? p.accent : p.bezel))
        case .tally:
            let fill: Color = on ? (hover ? Color(hex: 0xD92C22) : p.accent) : (hover && enabled ? p.accent2 : .clear)
            Text(title).bold()
                .frame(width: 150, height: 30)
                .foregroundColor(!enabled ? p.dim.opacity(0.6) : (on ? Color(hex: 0xFFF3E6) : (hover ? p.bg : p.accent2)))
                .background(RoundedRectangle(cornerRadius: 6).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(!enabled ? p.bezel : (on ? p.accent : p.accent2)))
        }
    }
}

/// A separator: Needle's line between two screw heads, Phosphor's dotted graticule line with a center tick,
/// Tally's plain hairline.
struct Separator: View {
    @Environment(\.palette) private var p
    var body: some View {
        Canvas { ctx, size in
            let y = size.height / 2
            switch p.look {
            case .needle:
                var l = Path(); l.move(to: CGPoint(x: 7, y: y)); l.addLine(to: CGPoint(x: size.width - 7, y: y))
                ctx.stroke(l, with: .color(p.line), lineWidth: 1)
                for x in [CGFloat(2), size.width - 2] {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(p.bezel))
                }
            case .phosphor:
                var x: CGFloat = 1
                while x < size.width { ctx.fill(Path(ellipseIn: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2)), with: .color(p.line)); x += 6 }
                ctx.fill(Path(CGRect(x: size.width / 2 - 0.5, y: y - 2.5, width: 1, height: 5)), with: .color(p.accent.opacity(0.6)))
            case .tally:
                ctx.fill(Path(CGRect(x: 0, y: y - 0.5, width: size.width, height: 1)), with: .color(p.line))
            }
        }
        .frame(height: 5).padding(.vertical, 4)
    }
}

/// The volume control, drawn per look; click or drag anywhere on it. It runs 0 to 200%: the left half is 0 to 100%
/// (the card's own level at the middle) and the right half is the boost, up to 2x, drawn in each look's hot color.
/// Needle: a meter scale with a red pointer and the boost as its red zone. Phosphor: a scope axis whose glowing set
/// line turns lime past 1x. Tally: a broadcast fader labelled in dB, amber then red above 0 dB.
struct VolumeScale: View {
    let percent: Int
    let onChange: (Int) -> Void
    @State private var hover = false
    @Environment(\.palette) private var p

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                switch p.look {
                case .needle: drawNeedle(ctx, size)
                case .phosphor: drawPhosphor(ctx, size)
                case .tally: drawTally(ctx, size)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let x = min(max(0, g.location.x), geo.size.width)
                var percent = Int((x / max(1, geo.size.width) * CGFloat(PassSettings.maxPercent)).rounded())
                if abs(percent - 100) <= 2 { percent = 100 }          // the card's own level is easy to land on
                onChange(percent)
            })
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .onHover { hover = $0 }
        .help("Click or drag to set the volume: 100% is the card's own level, up to 200% boosts it")
    }

    /// Where a percent sits along the control (0 to 1; 100% is the middle).
    private func at(_ percent: Double) -> CGFloat { CGFloat(percent / Double(PassSettings.maxPercent)) }
    private var v: CGFloat { at(Double(percent)) }
    private let unity: CGFloat = 0.5

    private func hline(_ ctx: GraphicsContext, _ from: CGFloat, _ to: CGFloat, _ y: CGFloat, _ color: Color, _ width: CGFloat,
                       cap: CGLineCap = .butt) {
        guard to > from else { return }
        var l = Path(); l.move(to: CGPoint(x: from, y: y)); l.addLine(to: CGPoint(x: to, y: y))
        ctx.stroke(l, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: cap))
    }

    private func drawNeedle(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, y: CGFloat = 9
        hline(ctx, 0, w, y, hover ? p.dim : p.bezel, 1)
        ctx.fill(Path(CGRect(x: w * unity, y: y - 1.5, width: w * (1 - unity), height: 3)), with: .color(p.accent2.opacity(0.25)))
        ctx.fill(Path(CGRect(x: w * unity - 0.5, y: y - 4, width: 1, height: 8)), with: .color(p.dim))
        hline(ctx, 1.5, min(v, unity) * w - (v <= unity ? 3 : 0), y, p.text, 3, cap: .round)
        if v > unity { hline(ctx, unity * w, v * w - 3, y, p.accent2, 3, cap: .round) }
        let px = min(w - 4, max(4, v * w))
        var pointer = Path()
        pointer.move(to: CGPoint(x: px, y: y - 2)); pointer.addLine(to: CGPoint(x: px - 4, y: 0)); pointer.addLine(to: CGPoint(x: px + 4, y: 0))
        pointer.closeSubpath()
        ctx.fill(pointer, with: .color(p.accent2))
        for n in [0, 50, 100, 150, 200] {
            let x = min(w - 8, max(5, at(Double(n)) * w))
            ctx.draw(Text("\(n)").font(.custom("Futura-CondensedMedium", size: 9)).foregroundColor(n > 100 ? p.accent2 : p.dim),
                     at: CGPoint(x: x, y: y + 10))
        }
    }

    private func drawPhosphor(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, y: CGFloat = 14
        let axis = p.dim.opacity(hover ? 1 : 0.6)
        hline(ctx, 0, w, y + 0.5, axis, 1)
        for i in 0...20 {
            let x = (CGFloat(i) / 20 * (w - 1)).rounded() + 0.5, tall = i % 10 == 0, mid = i % 5 == 0
            var t = Path(); t.move(to: CGPoint(x: x, y: y + 0.5)); t.addLine(to: CGPoint(x: x, y: y + (tall ? 7 : mid ? 4.5 : 2.5)))
            ctx.stroke(t, with: .color(i > 10 ? p.accent2.opacity(hover ? 0.9 : 0.5) : axis), lineWidth: 1)
        }
        func glow(_ from: CGFloat, _ to: CGFloat, _ color: Color, _ width: CGFloat) {
            guard to > from else { return }
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 2.5))
                var g = Path(); g.move(to: CGPoint(x: from, y: y)); g.addLine(to: CGPoint(x: to, y: y))
                l.stroke(g, with: .color(color), lineWidth: width + 1)
            }
            hline(ctx, from, to, y, color, width)
        }
        glow(0, min(v, unity) * w, p.accent, 2)
        if v > unity { glow(unity * w, v * w, p.accent2, 2.5) }        // the boost burns hotter
        let cx = min(w - 1, max(0.5, v * w))
        ctx.fill(Path(CGRect(x: cx - 0.6, y: y - 10, width: 1.2, height: 12)), with: .color(p.accent2))
        ctx.draw(Text("▾").font(.system(size: 8)).foregroundColor(p.accent2), at: CGPoint(x: min(w - 4, max(4, cx)), y: 2))
        ctx.draw(Text("1x").font(.system(size: 7, design: .monospaced)).foregroundColor(p.dim), at: CGPoint(x: unity * w + 7, y: y + 6))
    }

    private func drawTally(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, y: CGFloat = 8
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: y - 2, width: w, height: 4), cornerRadius: 2), with: .color(p.line))
        // Cream up to the card's own level (0 dB), amber to +3 dB, red to +6 dB.
        let plus3 = at(volumePercent(forDecibels: 3))
        for (from, to, color) in [(0, unity, p.text), (unity, plus3, p.waiting), (plus3, 1, p.accent)] where v > from {
            ctx.fill(Path(CGRect(x: from * w, y: y - 2, width: (min(v, to) - from) * w, height: 4)), with: .color(color))
        }
        ctx.fill(Path(CGRect(x: unity * w - 0.5, y: y - 4, width: 1, height: 8)), with: .color(p.dim))
        ctx.fill(Path(CGRect(x: min(w - 2, max(0, v * w - 1)), y: y - 6, width: 2, height: 12)), with: .color(p.text))
        for (label, db) in [("-∞", -200.0), ("-12", -12), ("-6", -6), ("0", 0), ("+3", 3), ("+6", 6)] {
            let x = min(w - 6, max(6, at(volumePercent(forDecibels: db)) * w))
            let color = db > 0 ? (db > 3 ? p.accent : p.waiting) : p.dim
            ctx.draw(Text(label).font(.system(size: 8, design: .monospaced)).foregroundColor(color), at: CGPoint(x: x, y: y + 12))
        }
    }
}

/// A single clickable word: no underline until hovered, pointer cursor, opens a URL.
struct HoverLink: View {
    let text: String
    let color: Color
    var bold = false
    let url: URL
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @State private var hover = false
    var body: some View {
        Text(text).bold(bold).foregroundColor(color).underline(hover)
            .onHover { inside in
                hover = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onTapGesture {
                if hover { hover = false; NSCursor.pop() }      // don't leave the hand cursor behind
                open(url)
            }
            .help(url.absoluteString)
    }
}

/// The look picker: the three names, the chosen one lit.
struct LookPicker: View {
    @ObservedObject var model: AppModel
    @Environment(\.palette) private var p
    var body: some View {
        HStack(spacing: 8) {
            Text(" ").bold()
            Image(systemName: "paintpalette").frame(width: 16).foregroundColor(p.dim)
            Text("look")
            Spacer()
            ForEach(Look.allCases, id: \.self) { look in
                LookChoice(name: look.rawValue, chosen: look == model.look) { model.setLook(look) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
    }
}

struct LookChoice: View {
    let name: String
    let chosen: Bool
    let action: () -> Void
    @State private var hover = false
    @Environment(\.palette) private var p
    var body: some View {
        Button(action: action) {
            Text(name).foregroundColor(chosen ? p.accent : (hover ? p.text : p.dim)).bold(chosen).underline(hover && !chosen)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover = $0 }
        .help("Switch to the \(name) look")
    }
}

// MARK: - Needle

/// The signal path: [card] ~~~▶ [speakers].
struct SignalChain: View {
    @ObservedObject var model: AppModel
    @Environment(\.palette) private var p
    var body: some View {
        let flowing = model.isFlowing, waiting = model.isWaiting
        let ends = flowing ? p.text : p.dim
        HStack(spacing: 6) {
            Text("[\((model.pass.selectedName ?? "capture card").lowercased())]").foregroundColor(ends)
                .lineLimit(1).truncationMode(.middle)
            Cable(model: model, flowing: flowing, waiting: waiting).frame(width: 50, height: 18)
            Text("▶").foregroundColor(flowing ? p.accent : (waiting ? p.waiting : p.dim))
            Text("[\((model.pass.selectedOutput?.name ?? "speakers").lowercased())]").foregroundColor(ends)
                .lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The cable from the card to the speakers. While sound flows it carries a waveform that travels toward the
/// speakers and grows with the sound level (from the meter's needle, so it moves with the same smooth timing);
/// it is dashed while Nerdpass waits for the card, and unplugged (a gap in the middle) when stopped.
struct Cable: View {
    let model: AppModel
    let flowing: Bool
    let waiting: Bool
    @Environment(\.palette) private var p
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !flowing)) { context in
            Canvas { ctx, size in
                let y = size.height / 2
                func line(_ from: CGFloat, _ to: CGFloat, _ color: Color, dash: [CGFloat] = []) {
                    var l = Path(); l.move(to: CGPoint(x: from, y: y)); l.addLine(to: CGPoint(x: to, y: y))
                    ctx.stroke(l, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: dash))
                }
                if flowing {
                    let wave = travellingWave(width: size.width, mid: y, level: model.meter.needle.position,
                                              time: context.date.timeIntervalSinceReferenceDate)
                    drawWave(ctx, wave, color: p.accent)
                } else if waiting {
                    line(0, size.width, p.waiting, dash: [4, 3])
                } else {
                    line(0, size.width * 0.38, p.dim)
                    line(size.width * 0.62, size.width, p.dim)
                }
            }
        }
    }
}

/// The wave's shape, shared by the panel and the menu bar icon: its height at `u` (0 to 1 along it), from -1 to 1
/// times `level` (0 to about 1). Pinned at both ends and travelling left to right. Silence is a flat line; quiet
/// sound is one smooth sine, and as it gets louder a faster second partial fades in, so it looks like sound rather
/// than a test tone without turning a near-silent ripple into jitter. `ripple: false` leaves the second partial out
/// (the menu bar icon, where it would crowd 16 pt into squiggles).
func waveHeight(at u: Double, level: Double, time t: Double, ripple: Bool = true) -> Double {
    let level = min(1, max(0, level))
    let detail = ripple ? 0.3 * min(1, level * 2.5) : 0
    let envelope = pow(sin(Double.pi * u), 0.8)
    let s = (1 - detail) * sin(2 * Double.pi * (u * 3 - t * 1.6)) + detail * sin(2 * Double.pi * (u * 7 - t * 2.9))
    return envelope * s * level
}

/// The wave as a path `width` wide around the line at `y`.
func travellingWave(width: CGFloat, mid y: CGFloat, level: Double, time t: Double, scale: CGFloat = 1) -> Path {
    var wave = Path()
    for i in 0...Int(width * 2) {
        let x = CGFloat(i) / 2
        let point = CGPoint(x: x, y: y - CGFloat(waveHeight(at: Double(x / width), level: level, time: t)) * (y - 2) * scale)
        if i == 0 { wave.move(to: point) } else { wave.addLine(to: point) }
    }
    return wave
}

/// Draws a wave the same way in every look: a soft glow under a 1.5 pt line with rounded joins, so bends stay smooth.
func drawWave(_ ctx: GraphicsContext, _ wave: Path, color: Color) {
    ctx.drawLayer { l in
        l.addFilter(.blur(radius: 2))
        l.stroke(wave, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }
    ctx.stroke(wave, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
}

// MARK: - Phosphor

/// A small scope screen fed by the sound. Waiting: a dashed amber line with a dot hunting for a trigger. Stopping:
/// the old TV power-off (the trace collapses to a line, then to a dot, then fades).
struct ScopeTrace: View {
    let model: AppModel
    @Environment(\.palette) private var p
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            Canvas { ctx, size in
                let m = model.meter, y = size.height / 2, t = context.date.timeIntervalSinceReferenceDate
                switch m.mode {
                case .flowing:
                    let wave = travellingWave(width: size.width, mid: y, level: m.needle.position, time: t)
                    drawWave(ctx, wave, color: p.accent)
                case .waiting:
                    var l = Path(); l.move(to: CGPoint(x: 0, y: y)); l.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(l, with: .color(p.waiting), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    let q = m.elapsed.truncatingRemainder(dividingBy: 1.6) / 1.6
                    ctx.fill(Path(ellipseIn: CGRect(x: q * size.width - 1.6, y: y - 1.6, width: 3.2, height: 3.2)), with: .color(Color(hex: 0xFFE2A8)))
                case .off:
                    crtOff(ctx, size: size, power: m.backlight, time: t, level: m.needle.position)
                }
            }
        }
    }

    /// `power` runs from 1 to 0 as the screen switches off: the trace flattens, shrinks to a dot, then fades.
    private func crtOff(_ ctx: GraphicsContext, size: CGSize, power: Double, time: Double, level: Double) {
        let y = size.height / 2
        guard power > 0 else {
            var l = Path(); l.move(to: CGPoint(x: 0, y: y)); l.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(l, with: .color(p.dim.opacity(0.6)), lineWidth: 1)
            return
        }
        if power > 0.55 {
            let wave = travellingWave(width: size.width, mid: y, level: level, time: time, scale: CGFloat((power - 0.55) / 0.45))
            drawWave(ctx, wave, color: p.accent)
        } else if power > 0.25 {
            let half = size.width / 2 * CGFloat((power - 0.25) / 0.30)
            var l = Path(); l.move(to: CGPoint(x: size.width / 2 - half, y: y)); l.addLine(to: CGPoint(x: size.width / 2 + half, y: y))
            ctx.stroke(l, with: .color(p.accent), lineWidth: 1.4)
        } else {
            ctx.fill(Path(ellipseIn: CGRect(x: size.width / 2 - 1.6, y: y - 1.6, width: 3.2, height: 3.2)),
                     with: .color(p.accent2.opacity(power / 0.25)))
        }
    }
}

/// On start(): a bright beam sweeps the status line and leaves an afterglow.
struct BeamSweep: View {
    let model: AppModel
    @Environment(\.palette) private var p
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            Canvas { ctx, size in
                let m = model.meter
                guard m.mode == .flowing, m.elapsed < 0.95 else { return }
                let head = size.width * 1.4 * CGFloat(min(1, m.elapsed / 0.35))
                let fade = m.elapsed < 0.35 ? 1 : max(0, 1 - (m.elapsed - 0.35) / 0.6)
                let rect = CGRect(x: head - size.width * 0.4, y: size.height / 2 - 1.5, width: size.width * 0.4, height: 3)
                ctx.drawLayer { l in
                    l.addFilter(.blur(radius: 1.5))
                    l.fill(Path(rect), with: .linearGradient(Gradient(colors: [p.accent2.opacity(0), p.accent2.opacity(0.85 * fade)]),
                                                             startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Tally

/// The 3 pt state strip across the top: red on air (wiping in on take()), amber on standby, green when the card is
/// ready, dark when there is nothing to take.
struct TallyStrip: View {
    @ObservedObject var model: AppModel
    @Environment(\.palette) private var p
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !model.isFlowing)) { _ in
            GeometryReader { geo in
                let m = model.meter
                ZStack(alignment: .leading) {
                    Rectangle().fill(model.isWaiting ? p.waiting : (model.pass.selected != nil ? p.accent2 : p.bezel))
                    if model.isFlowing {
                        let x = min(1, m.elapsed / 0.22)
                        Rectangle().fill(p.accent).frame(width: geo.size.width * CGFloat(1 - pow(1 - x, 3)))
                    }
                }
            }
        }
        .frame(height: 3)
    }
}

/// While on air: a red LIVE chip that pops in on take(), and a clock counting how long the card has been live.
struct OnAir: View {
    @ObservedObject var model: AppModel
    @Environment(\.palette) private var p
    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
                let x = min(1, model.meter.elapsed / 0.38), c1 = 1.70158, c3 = c1 + 1
                let pop = 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)             // ease out with a little overshoot
                Text("LIVE").font(.system(size: 10, weight: .heavy).width(.condensed)).tracking(1)
                    .foregroundColor(Color(hex: 0xFFF3E6))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(p.accent))
                    .scaleEffect(0.6 + 0.4 * pop)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(clockString(Int(context.date.timeIntervalSince(model.flowStartedAt ?? context.date))))
                    .foregroundColor(p.dim).monospacedDigit()
                    .help("How long the card has been on air")
            }
        }
    }
}

// MARK: - Panel

struct NerdView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let p = Palette.of(model.look)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                HoverLink(text: "nerdpass", color: p.title, bold: true, url: projectURL, open: { model.open($0) })
                Spacer()
                Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                    .foregroundColor(p.dim)
                    .help("build " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"))
            }
            ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in row(entry, p) }
        }
        .font(p.font)
        .foregroundColor(p.text)
        .padding(12)
        .frame(width: 330)
        .background(RoundedRectangle(cornerRadius: p.radius).fill(p.bg))
        .overlay(alignment: .top) {
            if p.look == .tally { TallyStrip(model: model).clipShape(UnevenRoundedRectangle(topLeadingRadius: p.radius, topTrailingRadius: p.radius)) }
        }
        .overlay { chrome(p) }
        .shadow(color: p.look == .phosphor ? p.accent.opacity(0.15) : .black.opacity(p.look == .needle ? 0.35 : 0.25),
                radius: p.look == .phosphor ? 6 : 10, y: p.look == .phosphor ? 0 : 5)
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 18, trailing: 12))     // room for the shadow
        .environment(\.palette, p)
    }

    /// The border: Needle's faceplate bezel with an inner highlight, Phosphor's instrument edge, Tally's hairline.
    @ViewBuilder private func chrome(_ p: Palette) -> some View {
        switch p.look {
        case .needle:
            RoundedRectangle(cornerRadius: p.radius - 1.5).strokeBorder(p.text.opacity(0.06), lineWidth: 1).padding(1.5)
            RoundedRectangle(cornerRadius: p.radius).strokeBorder(p.bezel, lineWidth: 1.5)
        case .phosphor, .tally:
            RoundedRectangle(cornerRadius: p.radius).strokeBorder(p.bezel, lineWidth: 1)
        }
    }

    private func statusColor(_ p: Palette) -> Color {
        switch model.pass.state {
        case .waiting: return p.waiting
        case .failed: return p.look == .tally ? p.accent : (p.look == .needle ? p.accent2 : p.waiting)
        case .flowing: return p.look == .phosphor ? p.accent : p.text
        case .stopped: return p.dim
        }
    }

    @ViewBuilder private func flow(_ status: String, on: Bool, enabled: Bool, _ p: Palette) -> some View {
        VStack(alignment: .center, spacing: 6) {
            switch p.look {
            case .needle:
                SignalChain(model: model)
                if !model.isFlowing {
                    Text(status).foregroundColor(statusColor(p)).lineLimit(1).truncationMode(.middle)
                }
            case .phosphor:
                HStack(spacing: 8) {
                    ScopeTrace(model: model).frame(width: 50, height: 18)
                    Text(status.lowercased()).foregroundColor(statusColor(p)).bold().lineLimit(1).truncationMode(.middle)
                }
                .padding(.vertical, 2)
                .overlay { BeamSweep(model: model) }
            case .tally:
                // One row, like the other looks: LIVE and the clock lead while on air.
                HStack(spacing: 8) {
                    if model.isFlowing { OnAir(model: model).fixedSize() }
                    Text(status.lowercased()).foregroundColor(statusColor(p)).lineLimit(1).truncationMode(.middle)
                }
            }
            FlowButton(on: on, enabled: enabled) { model.toggle() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func item(checked: Bool, symbol: String, title: String, _ p: Palette) -> some View {
        HStack(spacing: 8) {
            Text(checked ? ">" : " ").foregroundColor(p.accent).bold()
            Image(systemName: symbol).frame(width: 16).foregroundColor(checked ? p.accent : p.dim)
            Text(title).foregroundColor(checked ? p.checkedText : p.text).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
    }

    @ViewBuilder private func row(_ entry: MenuEntry, _ p: Palette) -> some View {
        switch entry {
        case let .flow(status, on, enabled):
            flow(status, on: on, enabled: enabled, p)
        case .volume:
            HStack(spacing: 6) {
                Text("vol").foregroundColor(p.dim)
                VolumeScale(percent: model.volumePercent) { model.setVolume($0) }
                Text("\(model.volumePercent)%").foregroundColor(model.volumePercent > 100 ? p.boost : p.text).monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
                    .help(model.volumePercent > 100 ? "Boosted: \(String(format: "%.1f", Double(model.volumePercent) / 100))x the card's level" : "")
            }.padding(.vertical, 2)
        case .separator:
            Separator()
        case let .header(text):
            Text(text).foregroundColor(p.dim).padding(.horizontal, 8).padding(.top, 2)
        case .noInputs:
            Text("// no audio inputs: plug in your capture card").foregroundColor(p.dim).lineLimit(1)
        case .permission:
            RowButton(action: { model.openPrivacySettings() }) {
                HStack(spacing: 8) {
                    Text(" ")
                    Image(systemName: "exclamationmark.triangle.fill").frame(width: 16).foregroundColor(p.waiting)
                    Text("allow_audio_input").foregroundColor(p.waiting).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 4)
                    Text("settings ↗").foregroundColor(p.dim).lineLimit(1).fixedSize()
                }
            }
            .help("Turn on Nerdpass in System Settings > Privacy & Security > Microphone (capture cards count as one)")
        case let .input(name, symbol, checked):
            RowButton(action: { model.select(name) }) { item(checked: checked, symbol: symbol, title: name, p) }
        case let .output(name, symbol, checked):
            RowButton(action: { model.selectOutput(name) }) { item(checked: checked, symbol: symbol, title: name ?? "system_default", p) }
                .help(name.map { "Play to \($0)" } ?? "Play to the Mac's current output (follows Sound settings)")
        case .look:
            LookPicker(model: model)
        case .feedback:
            RowButton(action: { model.openFeedback() }) {
                HStack(spacing: 8) {
                    Text(" ").bold()
                    Image(systemName: "bubble.left.and.text.bubble.right").frame(width: 16).foregroundColor(p.dim)
                    Text("feedback")
                    Spacer()
                    Text("github ↗").foregroundColor(p.dim)
                }
            }
        case let .alwaysOn(on):
            RowButton(action: model.toggleAlwaysOn) { item(checked: on, symbol: "infinity", title: "always_on", p) }
                .help("Start the sound every time Nerdpass opens (with open_at_login: whenever you log in)")
        case let .openAtLogin(on):
            RowButton(action: model.toggleLogin) { item(checked: on, symbol: "laptopcomputer", title: "open_at_login", p) }
        case .exit:
            RowButton(action: { model.onQuit?() }) {
                HStack(spacing: 8) {
                    Text(" ").bold()
                    Image(systemName: "power").frame(width: 16).foregroundColor(p.dim)
                    Text("exit()")
                    Spacer()
                    Text("⌘Q").foregroundColor(p.dim)
                }
            }
        }
    }
}

// MARK: - Menu bar icon

/// The menu bar icon, per look, in the family's rounded ring. Stopped, it is a template image (macOS tints it).
/// Needle: a tiny VU meter whose needle follows the sound (orange), or sweeps slowly while waiting (blue).
/// Phosphor: a scope screen with a live trace (green); waiting, a dot hunts along a dashed line (amber); stopping
/// plays the TV power-off. Tally: a lamp, solid red and still while on air, blinking amber on standby.
enum StatusIcon {
    static let size = NSSize(width: 22, height: 22)

    static func isTemplate(_ look: Look, _ meter: MeterAnimator) -> Bool {
        look == .tally ? meter.mode == .off : meter.isIdle
    }

    static func image(look: Look, meter: MeterAnimator, darkMenuBar: Bool) -> NSImage {
        let p = Palette.of(look), template = isTemplate(look, meter)
        let ink: NSColor = template ? .black : (darkMenuBar ? p.inkDarkBarNS : p.inkLightBarNS)
        let img = NSImage(size: size, flipped: true) { _ in
            switch look {
            case .needle: drawNeedle(meter, p, ink, template)
            case .phosphor: drawPhosphor(meter, p, ink, template)
            case .tally: drawTally(meter, p, ink, template)
            }
            return true
        }
        img.isTemplate = template
        return img
    }

    private static func ring(_ color: NSColor) {
        let frame = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 19, height: 19), xRadius: 5.5, yRadius: 5.5)
        frame.lineWidth = 1.8
        color.setStroke(); frame.stroke()
    }

    private static func drawNeedle(_ meter: MeterAnimator, _ p: Palette, _ ink: NSColor, _ template: Bool) {
        let ringColor: NSColor
        switch meter.mode {
        case .flowing: ringColor = p.accentNS.withAlphaComponent(0.3 + 0.7 * meter.backlight)
        case .waiting: ringColor = p.waitingNS
        case .off: ringColor = template ? .black : ink.blended(withFraction: meter.backlight, of: p.accentNS) ?? ink
        }
        ring(ringColor)
        let pivot = NSPoint(x: 11, y: 17)
        func point(_ position: Double, _ r: CGFloat) -> NSPoint {
            let a = (-45 + position * 90) * Double.pi / 180
            return NSPoint(x: pivot.x + CGFloat(sin(a)) * r, y: pivot.y - CGFloat(cos(a)) * r)
        }
        let arc = NSBezierPath()
        arc.move(to: point(0, 9))
        for i in 1...16 { arc.line(to: point(Double(i) / 16, 9)) }
        arc.lineWidth = 1.2
        (meter.mode == .off ? ink : ringColor).setStroke(); arc.stroke()
        let needle = NSBezierPath()
        needle.move(to: pivot); needle.line(to: point(min(1.08, meter.needle.position), 10))
        needle.lineWidth = 1.4; needle.lineCapStyle = .round
        ink.setStroke(); needle.stroke()
        if !template, meter.needle.position > needleRedZone {
            p.accent2NS.setFill()
            NSBezierPath(ovalIn: NSRect(x: 16.2, y: 7.6, width: 2.8, height: 2.8)).fill()
        }
    }

    private static func drawPhosphor(_ meter: MeterAnimator, _ p: Palette, _ ink: NSColor, _ template: Bool) {
        let screen = NSBezierPath(roundedRect: NSRect(x: 2, y: 4, width: 18, height: 14), xRadius: 4, yRadius: 4)
        screen.lineWidth = 1.5
        let bezel: NSColor = template ? .black : (meter.mode == .waiting ? p.waitingNS : p.accentNS.withAlphaComponent(0.75))
        bezel.setStroke(); screen.stroke()
        NSGraphicsContext.saveGraphicsState()
        screen.addClip()
        let trace = NSBezierPath(); trace.lineWidth = 1.6; trace.lineCapStyle = .round; trace.lineJoinStyle = .round
        let t = Date().timeIntervalSinceReferenceDate
        // The panel's wave without its fast ripple, scaled down to the screen: 16 pt wide, up to 5 pt either way.
        func wave(_ scale: Double) {
            for i in 0...64 {
                let u = Double(i) / 64
                let y = 11 - CGFloat(waveHeight(at: u, level: meter.needle.position, time: t, ripple: false) * 5 * scale)
                let point = NSPoint(x: 3 + 16 * CGFloat(u), y: y)
                i == 0 ? trace.move(to: point) : trace.line(to: point)
            }
        }
        switch meter.mode {
        case .flowing:
            wave(1); ink.setStroke(); trace.stroke()
        case .waiting:
            trace.move(to: NSPoint(x: 4, y: 11)); trace.line(to: NSPoint(x: 18, y: 11))
            trace.setLineDash([1.5, 1.5], count: 2, phase: 0); trace.lineWidth = 1.2
            p.waitingNS.setStroke(); trace.stroke()
            let q = meter.elapsed.truncatingRemainder(dividingBy: 1.6) / 1.6
            NSColor(hex: 0xFFE2A8).setFill()
            NSBezierPath(ovalIn: NSRect(x: 4 + 14 * q - 1.4, y: 9.6, width: 2.8, height: 2.8)).fill()
        case .off:
            let power = meter.backlight
            if template || power == 0 {
                trace.move(to: NSPoint(x: 4, y: 11)); trace.line(to: NSPoint(x: 18, y: 11)); ink.setStroke(); trace.stroke()
            } else if power > 0.55 {
                wave((power - 0.55) / 0.45); ink.setStroke(); trace.stroke()
            } else if power > 0.25 {
                let half = 7 * CGFloat((power - 0.25) / 0.30)
                trace.move(to: NSPoint(x: 11 - half, y: 11)); trace.line(to: NSPoint(x: 11 + half, y: 11)); ink.setStroke(); trace.stroke()
            } else {
                p.accent2NS.withAlphaComponent(power / 0.25).setFill()
                NSBezierPath(ovalIn: NSRect(x: 9.6, y: 9.6, width: 2.8, height: 2.8)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawTally(_ meter: MeterAnimator, _ p: Palette, _ ink: NSColor, _ template: Bool) {
        let lamp = NSBezierPath(ovalIn: NSRect(x: 5.8, y: 5.8, width: 10.4, height: 10.4))
        lamp.lineWidth = 1.6
        switch meter.mode {
        case .flowing:
            ring(p.accentNS); p.accentNS.setFill(); lamp.fill()
        case .waiting:
            ring(p.waitingNS)
            if Int(meter.elapsed / 0.5) % 2 == 0 { p.waitingNS.setStroke(); lamp.stroke() }      // hard 1 Hz blink
        case .off:
            ring(ink); ink.setStroke(); lamp.stroke()
        }
    }
}

/// Borderless floating panel shown under the menu bar icon.
final class NerdPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model = AppModel()
    private var panel: NerdPanel?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var deviceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        // `--unregister-login` removes this app from Login Items and quits (used before renaming/removing it).
        if args.contains("--unregister-login") {
            try? SMAppService.mainApp.unregister()
            exit(0)
        }
        // `--list-inputs` prints the audio inputs (★ = looks like a capture card) and outputs Nerdpass sees, and quits.
        if args.contains("--list-inputs") {
            for input in listInputs() { print(input.looksLikeCaptureCard ? "★" : " ", input.name, " [\(input.id)]") }
            print("outputs:")
            for output in listOutputs() { print("  ", output.name, " [\(output.id)]") }
            exit(0)
        }
        // `--audio-check [seconds] [--volume <percent>]` plays the saved input to the saved output for a few seconds
        // (8 by default) and prints, each second, the frames received and played, the buffer's delay, dropouts,
        // catch-ups and the level, then quits. For checking the audio path; quit the menu bar Nerdpass first.
        if let i = args.firstIndex(of: "--audio-check") {
            audioCheck(seconds: args.indices.contains(i + 1) ? Double(args[i + 1]) ?? 8 : 8,
                       volume: args.firstIndex(of: "--volume").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil })
            exit(0)
        }
        // `--snapshot-icons <file.png>` renders the menu bar icon of every look (stopped, flowing, waiting, and the
        // moment after stopping) on a light and a dark menu bar, at 4x, and quits.
        if let i = args.firstIndex(of: "--snapshot-icons"), args.indices.contains(i + 1) {
            snapshotIcons(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        // `--snapshot <file.png>` renders the panel to an image and quits (for checking the UI without clicking).
        // With `--demo` it shows made-up inputs with the sound on, and leaves the settings alone (for the README);
        // `--look needle|phosphor|tally` picks the look, and `--level <dBFS>` the sound level (-22 by default);
        // `--denied` shows the row for allowing audio input.
        if let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) {
            let shown: AppModel
            if args.contains("--demo") {
                shown = AppModel(backend: SilentBackend(), settings: PassSettings(defaults: UserDefaults(suiteName: "nerdpass-demo")!))
                shown.pass.updateInputs([AudioInput(id: "card", name: "Elgato 4K X"),
                                         AudioInput(id: "mic", name: "MacBook Pro Microphone"),
                                         AudioInput(id: "usb", name: "USB Audio Interface")])
                shown.pass.updateOutputs([AudioOutput(id: "spk", name: "MacBook Pro Speakers"),
                                          AudioOutput(id: "phones", name: "AirPods Pro")])
                if let j = args.firstIndex(of: "--look"), args.indices.contains(j + 1), let look = Look(rawValue: args[j + 1]) {
                    shown.pass.setLook(look)
                }
                shown.pass.start()
                shown.refresh()
                shown.flowStartedAt = Date().addingTimeInterval(-764)
                shown.showDenied = args.contains("--denied")
                if let j = args.firstIndex(of: "--level"), args.indices.contains(j + 1), let db = Float(args[j + 1]) {
                    shown.levelDecibels = { db }
                    for _ in 0..<60 { shown.stepMeter(1.0 / 30) }
                }
                for _ in 0..<60 { shown.stepMeter(1.0 / 30) }
            } else {
                shown = model
                shown.outputsChanged()
                shown.inputsChanged()
            }
            shown.refresh()
            snapshot(shown, to: URL(fileURLWithPath: args[i + 1]))
            UserDefaults().removePersistentDomain(forName: "nerdpass-demo")
            exit(0)
        }

        if let button = statusItem.button {
            button.image = StatusIcon.image(look: model.look, meter: model.meter, darkMenuBar: isDarkMenuBar)
            button.imageScaling = .scaleNone
            button.toolTip = "Nerdpass"
            button.target = self
            button.action = #selector(togglePanel)
        }
        model.onQuit = { NSApp.terminate(nil) }
        model.closePanel = { [weak self] in self?.closePanel() }
        model.onRefresh = { [weak self] in self?.stateChanged() }

        // Capture cards come and go (unplugged, switched off, asleep): follow them.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // The device list updates a moment after the notification.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.model.inputsChanged() }
            })
        }
        watchAudioDevices(devicesChanged: { [weak self] in self?.model.outputsChanged() },
                          defaultChanged: { [weak self] in self?.model.pass.defaultOutputChanged() })
        model.outputsChanged()
        model.inputsChanged()
        model.defaultLoginOnce()
        // `--start` turns the sound on right away (for testing or a Stream Deck) even when always on is off.
        if args.contains("--start") { model.start() } else { model.launch() }
        model.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.pass.shutdown()
    }

    private func audioCheck(seconds: Double, volume: Int?) {
        let backend = CaptureBackend(), settings = PassSettings()
        let pass = Passthrough(backend: backend, settings: settings)
        pass.updateInputs(listInputs())
        pass.updateOutputs(listOutputs())
        guard let input = pass.selected else { print("no input picked or connected"); return }
        let percent = volume ?? settings.volumePercent
        do {
            try backend.start(inputID: input.id, outputID: pass.selectedOutput?.id, amplitude: amplitude(percent: percent))
        } catch { print("can't start: \(error.localizedDescription)"); return }
        print("\(input.name) -> \(pass.selectedOutput?.name ?? "default output") at \(percent)% (gain \(amplitude(percent: percent)))")
        var lastIn = 0, lastOut = 0
        for second in 1...Int(seconds) {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let fill = backend.ring.fill
            print(String(format: "%2ds  in %5d/s  out %5d/s  delay %3.0f ms  dropouts %d  catch-ups %d  level %6.1f dBFS",
                         second, backend.levels.framesIn - lastIn, backend.framesOut - lastOut,
                         Double(fill) / CaptureBackend.sampleRate * 1000, backend.ring.underruns, backend.ring.dropped,
                         backend.levels.take()))
            lastIn = backend.levels.framesIn; lastOut = backend.framesOut
        }
        backend.stop()
    }

    private func snapshotIcons(to url: URL) {
        func meter(_ mode: MeterAnimator.Mode, seconds: Double, then: MeterAnimator.Mode? = nil, after: Double = 0) -> MeterAnimator {
            var m = MeterAnimator()
            m.setMode(mode)
            for _ in 0..<Int(seconds * 30) { m.step(dt: 1.0 / 30, level: 0.75) }
            if let then { m.setMode(then); for _ in 0..<Int(after * 30) { m.step(dt: 1.0 / 30, level: 0.75) } }
            return m
        }
        let states = [meter(.off, seconds: 0), meter(.flowing, seconds: 2), meter(.waiting, seconds: 1.2),
                      meter(.flowing, seconds: 2, then: .off, after: 0.12)]
        let cell: CGFloat = 26, scale: CGFloat = 4
        let size = NSSize(width: cell * CGFloat(states.count * 2), height: cell * CGFloat(Look.allCases.count))
        let image = NSImage(size: NSSize(width: size.width * scale, height: size.height * scale), flipped: true) { _ in
            NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
            for (row, look) in Look.allCases.enumerated() {
                for (dark, bar) in [(false, NSColor(white: 0.92, alpha: 1)), (true, NSColor(white: 0.17, alpha: 1))].enumerated().map({ ($0.element.0, $0.element.1) }) {
                    for (col, m) in states.enumerated() {
                        let x = CGFloat(col + (dark ? states.count : 0)) * cell, y = CGFloat(row) * cell
                        bar.setFill(); NSRect(x: x, y: y, width: cell, height: cell).fill()
                        let icon = StatusIcon.image(look: look, meter: m, darkMenuBar: dark)
                        let r = NSRect(x: x + 2, y: y + 2, width: 22, height: 22)
                        if icon.isTemplate {
                            // Tinted like macOS does: black on a light bar, white on a dark one.
                            let tinted = NSImage(size: icon.size, flipped: false) { rect in
                                icon.draw(in: rect); (dark ? NSColor.white : NSColor.black).set(); rect.fill(using: .sourceAtop); return true
                            }
                            tinted.draw(in: r)
                        } else { icon.draw(in: r) }
                    }
                }
            }
            return true
        }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }

    private func snapshot(_ model: AppModel, to url: URL) {
        let host = NSHostingView(rootView: NerdView(model: model))
        let size = host.fittingSize
        // Drawn through a real (offscreen) window at 2x, like Nerdwave's snapshots.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        }
    }

    private var iconTimer: Timer?
    private var lastTick = Date()

    private var isDarkMenuBar: Bool {
        statusItem.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Runs the meter at 30 frames a second while there is something to animate (sound flowing, waiting for the
    /// card, or the needle and backlight still settling after a stop). Then the timer stops and the icon holds still.
    private func updateStatusIcon() {
        statusItem.button?.toolTip = "Nerdpass: " + statusLine(model.pass.state, output: model.pass.selectedOutput?.name)
        model.stepMeter(0)
        statusItem.button?.image = StatusIcon.image(look: model.look, meter: model.meter, darkMenuBar: isDarkMenuBar)
        guard iconTimer == nil, !model.meter.isIdle else { return }
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { return }
            let now = Date()
            self.model.stepMeter(now.timeIntervalSince(self.lastTick))
            self.lastTick = now
            self.statusItem.button?.image = StatusIcon.image(look: self.model.look, meter: self.model.meter, darkMenuBar: self.isDarkMenuBar)
            if self.model.meter.isIdle { timer.invalidate(); self.iconTimer = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        iconTimer = t
    }

    private func stateChanged() {
        updateStatusIcon()
        resizePanel()
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true { closePanel() } else { openPanel() }
    }

    private func openPanel() {
        closePanel()                        // never stack monitors
        model.refresh()
        let p = panel ?? makePanel()
        panel = p
        resizePanel()
        p.orderFrontRegardless()
        p.makeKey()
        // Clicks outside close the panel, except on our own menu bar icon: that click reaches togglePanel.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if let frame = self.statusItem.button?.window?.frame, frame.contains(NSEvent.mouseLocation) { return }
            self.closePanel()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.closePanel(); return nil }                         // Esc
            if e.charactersIgnoringModifiers == " " { self?.model.toggle(); return nil }   // Space starts/stops
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "q" { NSApp.terminate(nil) }
            return e
        }
    }

    private func closePanel() {
        panel?.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil; keyMonitor = nil
    }

    private func makePanel() -> NerdPanel {
        let p = NerdPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 300),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: NerdView(model: model))
        return p
    }

    /// Fits the panel to its content and keeps it just under the menu bar icon.
    private func resizePanel() {
        guard let p = panel, let hosting = p.contentView, let button = statusItem.button,
              let bwin = button.window else { return }
        let size = hosting.fittingSize
        let b = bwin.frame
        let screen = bwin.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = b.midX - size.width / 2
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        p.setFrame(NSRect(x: x, y: b.minY - size.height + 6, width: size.width, height: size.height), display: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
