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

/// Measures the sound level of each audio buffer (for the meter), on the capture queue.
final class LevelTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var latest: Float = -120
    private var peak: Float?

    /// The loudest buffer's RMS level in dBFS since the last call, so a short hit between two frames still
    /// shows. With no new buffer since then, the last level again.
    func take() -> Float {
        lock.lock(); defer { lock.unlock() }
        if let p = peak { latest = p; peak = nil }
        return latest
    }

    func reset() {
        lock.lock(); latest = -120; peak = nil; lock.unlock()
    }

    private func record(_ db: Float) {
        lock.lock(); peak = max(peak ?? -120, db); lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let format = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0, bits = format.mBitsPerChannel
        var loudest: Float = -120
        try? sampleBuffer.withAudioBufferList { list, _ in
            for buffer in list {
                guard let data = buffer.mData else { continue }
                if isFloat, bits == 32 {
                    let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(buffer.mDataByteSize) / 4)
                    loudest = max(loudest, rmsDecibels(samples))
                } else if bits == 16 || bits == 32 {
                    // Integer samples (what most USB capture cards send): scale to -1...1 first.
                    let count = Int(buffer.mDataByteSize) / Int(bits / 8)
                    var floats = [Float](repeating: 0, count: count)
                    if bits == 16 {
                        let ints = data.assumingMemoryBound(to: Int16.self)
                        for i in 0..<count { floats[i] = Float(ints[i]) / 32768 }
                    } else {
                        let ints = data.assumingMemoryBound(to: Int32.self)
                        for i in 0..<count { floats[i] = Float(ints[i]) / 2_147_483_648 }
                    }
                    loudest = max(loudest, floats.withUnsafeBufferPointer(rmsDecibels))
                }
            }
        }
        record(loudest)
    }
}

/// Plays an input live through the Mac's default output, like QuickTime's preview (the same way `sw` did),
/// and measures its level for the meter.
final class CaptureBackend: PassBackend {
    private var session: AVCaptureSession?
    let levels = LevelTap()
    private let levelQueue = DispatchQueue(label: "nerdpass.level")
    private var preview: AVCaptureAudioPreviewOutput?
    private var errorObserver: NSObjectProtocol?
    /// startRunning and stopRunning block, so they run off the main thread, in order.
    private let queue = DispatchQueue(label: "nerdpass.session")
    /// Called on the main thread when a running session fails (for example the card is in use elsewhere).
    var onError: ((String) -> Void)?

    func start(inputID: String, outputID: String?, amplitude: Float) throws {
        stop()
        guard let device = AVCaptureDevice(uniqueID: inputID) else { throw PassError(errorDescription: "not connected") }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let preview = AVCaptureAudioPreviewOutput()
        preview.volume = amplitude
        preview.outputDeviceUniqueID = outputID          // nil: the Mac's default output
        guard session.canAddInput(input), session.canAddOutput(preview) else {
            throw PassError(errorDescription: "can't route its sound")
        }
        session.addInput(input)
        session.addOutput(preview)
        // A second output only for the meter; it doesn't change what you hear.
        let meter = AVCaptureAudioDataOutput()
        meter.setSampleBufferDelegate(levels, queue: levelQueue)
        if session.canAddOutput(meter) { session.addOutput(meter) }
        errorObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                               object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onError?("audio stopped: \(error?.localizedDescription ?? "unknown error")")
        }
        self.session = session
        self.preview = preview
        queue.async { session.startRunning() }
    }

    func stop() {
        if let o = errorObserver { NotificationCenter.default.removeObserver(o) }
        errorObserver = nil
        if let s = session { queue.async { s.stopRunning() } }
        session = nil
        preview = nil
        levels.reset()
    }

    func setAmplitude(_ amplitude: Float) { preview?.volume = amplitude }
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

    var accessDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .audio)
        return s == .denied || s == .restricted
    }

    func refresh() {
        volumePercent = pass.volumePercent
        if case .flowing = pass.state { isFlowing = true } else { isFlowing = false }
        if case .waiting = pass.state { isWaiting = true } else { isWaiting = false }
        entries = menuEntries(for: MenuState(
            flow: pass.state, inputs: pass.inputs, selectedID: pass.selected?.id,
            outputs: pass.outputs, selectedOutputID: pass.selectedOutput?.id, volumePercent: volumePercent,
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

// MARK: - Needle panel

/// Nerdpass's look: a backlit analog VU meter on a walnut hi-fi faceplate.
enum Theme {
    static let bg = Color(red: 0.086, green: 0.071, blue: 0.047)         // #16120C walnut
    static let surface = Color(red: 0.133, green: 0.106, blue: 0.071)    // #221B12
    static let text = Color(red: 0.957, green: 0.914, blue: 0.831)       // #F4E9D4 cream
    static let dim = Color(red: 0.627, green: 0.557, blue: 0.439)        // #A08E70
    static let orange = Color(red: 1.000, green: 0.624, blue: 0.110)     // #FF9F1C meter backlight
    static let red = Color(red: 0.910, green: 0.271, blue: 0.173)        // #E8452C needle red
    static let blue = Color(red: 0.424, green: 0.706, blue: 1.000)       // #6CB4FF pilot blue, waiting
    static let bezel = Color(red: 0.227, green: 0.180, blue: 0.118)      // #3A2E1E
    static let line = Color(red: 0.180, green: 0.141, blue: 0.094)       // #2E2418
    static let unlit = Color(red: 0.165, green: 0.125, blue: 0.086)      // #2A2016 meter face with the lamp off
    static let ink = Color(red: 0.102, green: 0.071, blue: 0.031)        // #1A1208 needle and printing on the face
    static let font = Font.system(size: 13, design: .monospaced)
    static let scaleFont = Font.custom("Futura-CondensedMedium", size: 9)
    static let orangeNS = NSColor(red: 1.000, green: 0.624, blue: 0.110, alpha: 1)
    static let redNS = NSColor(red: 0.910, green: 0.271, blue: 0.173, alpha: 1)
    static let blueNS = NSColor(red: 0.424, green: 0.706, blue: 1.000, alpha: 1)
    static let creamNS = NSColor(red: 0.957, green: 0.914, blue: 0.831, alpha: 1)
    static let darkInkNS = NSColor(red: 0.227, green: 0.165, blue: 0.071, alpha: 1)
}

/// A row that warms up on hover, like a lit button on a faceplate.
struct RowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Theme.orange.opacity(0.10) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover = $0 }
    }
}

/// Moves the label down a point while pressed, like a rocker switch.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.offset(y: configuration.isPressed ? 1 : 0)
    }
}

/// The start/stop rocker: a pilot light, the label, an orange outline that fills on hover.
struct RockerButton: View {
    let on: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(on ? Theme.orange : Theme.bezel).frame(width: 6, height: 6)
                    .shadow(color: on ? Theme.orange : .clear, radius: 3)
                Text(on ? "stop()" : "start()").bold()
            }
            .frame(width: 130, height: 30)
            .foregroundColor(enabled ? (hover ? Theme.bg : Theme.text) : Theme.dim.opacity(0.6))
            .background(RoundedRectangle(cornerRadius: 8).fill(hover && enabled ? Theme.orange : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(enabled ? Theme.orange : Theme.bezel))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .focusable(false)
        .disabled(!enabled)
        .help(on ? "Stop the sound" : "Play the capture card's sound through this Mac")
        .onHover { hover = $0 }
    }
}

/// The signal path: [card] ~~~▶ [speakers].
struct SignalChain: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let flowing = model.isFlowing, waiting = model.isWaiting
        let ends = flowing ? Theme.text : Theme.dim
        HStack(spacing: 6) {
            Text("[\((model.pass.selectedName ?? "capture card").lowercased())]").foregroundColor(ends)
                .lineLimit(1).truncationMode(.middle)
            Cable(model: model, flowing: flowing, waiting: waiting).frame(width: 50, height: 18)
            Text("▶").foregroundColor(flowing ? Theme.orange : (waiting ? Theme.blue : Theme.dim))
            Text("[\((model.pass.selectedOutput?.name ?? "speakers").lowercased())]").foregroundColor(ends)
                .lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The cable from the card to the speakers. While sound flows it carries a waveform that travels toward the
/// speakers and grows with the sound level (from the meter's needle, so it moves with the same smooth timing);
/// it is dashed blue while Nerdpass waits for the card, and unplugged (a gap in the middle) when stopped.
struct Cable: View {
    let model: AppModel
    let flowing: Bool
    let waiting: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !flowing)) { context in
            Canvas { ctx, size in
                let y = size.height / 2
                func line(_ from: CGFloat, _ to: CGFloat, _ color: Color, dash: [CGFloat] = []) {
                    var p = Path(); p.move(to: CGPoint(x: from, y: y)); p.addLine(to: CGPoint(x: to, y: y))
                    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: dash))
                }
                if flowing {
                    let t = context.date.timeIntervalSinceReferenceDate
                    let level = min(1, max(0, model.meter.needle.position))
                    let amp = 1.2 + level * (y - 2)
                    var wave = Path()
                    for i in 0...Int(size.width) {
                        let x = CGFloat(i), u = Double(x / size.width)
                        // Pinned to the cable at both ends; two partials so it looks like sound, not a test tone.
                        let envelope = pow(sin(Double.pi * u), 0.8)
                        let s = 0.7 * sin(2 * Double.pi * (u * 3 - t * 1.6)) + 0.3 * sin(2 * Double.pi * (u * 7 - t * 2.9))
                        let point = CGPoint(x: x, y: y - CGFloat(envelope * s) * amp)
                        if i == 0 { wave.move(to: point) } else { wave.addLine(to: point) }
                    }
                    ctx.drawLayer { l in
                        l.addFilter(.blur(radius: 2))
                        l.stroke(wave, with: .color(Theme.orange.opacity(0.7)), lineWidth: 2.5)
                    }
                    ctx.stroke(wave, with: .color(Theme.orange), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                } else if waiting {
                    line(0, size.width, Theme.blue, dash: [4, 3])
                } else {
                    line(0, size.width * 0.38, Theme.dim)
                    line(size.width * 0.62, size.width, Theme.dim)
                }
            }
        }
    }
}

/// A separator: a thin line between two screw heads.
struct Faceplate: View {
    var body: some View {
        Canvas { ctx, size in
            let y = size.height / 2
            var p = Path(); p.move(to: CGPoint(x: 7, y: y)); p.addLine(to: CGPoint(x: size.width - 7, y: y))
            ctx.stroke(p, with: .color(Theme.line), lineWidth: 1)
            for x in [CGFloat(2), size.width - 2] {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(Theme.bezel))
            }
        }
        .frame(height: 5).padding(.vertical, 4)
    }
}

struct NerdView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                HoverLink(text: "nerdpass", color: Theme.orange, bold: true, url: projectURL, open: { model.open($0) })
                Spacer()
                Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                    .foregroundColor(Theme.dim)
                    .help("build " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"))
            }
            ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in row(entry) }
        }
        .font(Theme.font)
        .foregroundColor(Theme.text)
        .padding(12)
        .frame(width: 330)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 12.5).strokeBorder(Theme.text.opacity(0.06), lineWidth: 1).padding(1.5))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.bezel, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 18, trailing: 12))     // room for the shadow
    }

    private var statusColor: Color {
        switch model.pass.state {
        case .waiting: return Theme.blue
        case .failed: return Theme.red
        default: return Theme.dim
        }
    }

    @ViewBuilder private func row(_ entry: MenuEntry) -> some View {
        switch entry {
        case let .flow(status, on, enabled):
            VStack(alignment: .center, spacing: 6) {
                SignalChain(model: model)
                if !model.isFlowing {
                    Text(status).foregroundColor(statusColor).lineLimit(1).truncationMode(.middle)
                }
                RockerButton(on: on, enabled: enabled) { model.toggle() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        case .volume:
            HStack(spacing: 6) {
                Text("vol").foregroundColor(Theme.dim)
                VolumeScale(percent: model.volumePercent) { model.setVolume($0) }
                Text("\(model.volumePercent)%").foregroundColor(Theme.text).monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }.padding(.vertical, 2)
        case .separator:
            Faceplate()
        case let .header(text):
            Text(text).foregroundColor(Theme.dim).padding(.horizontal, 8).padding(.top, 2)
        case let .output(name, symbol, checked):
            RowButton(action: { model.selectOutput(name) }) {
                HStack(spacing: 8) {
                    Text(checked ? ">" : " ").foregroundColor(Theme.orange).bold()
                    Image(systemName: symbol).frame(width: 16).foregroundColor(checked ? Theme.orange : Theme.dim)
                    Text(name ?? "system_default").foregroundColor(checked ? Theme.orange : Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
            }
            .help(name == nil ? "Play to the Mac's current output (follows Sound settings)" : "Play to \(name!)")
        case .noInputs:
            Text("// no audio inputs: plug in your capture card").foregroundColor(Theme.dim).lineLimit(1)
        case .permission:
            RowButton(action: { model.openPrivacySettings() }) {
                HStack(spacing: 8) {
                    Text(" ")
                    Image(systemName: "exclamationmark.triangle.fill").frame(width: 16).foregroundColor(Theme.red)
                    Text("allow_audio_input…").foregroundColor(Theme.red)
                    Spacer()
                    Text("settings ↗").foregroundColor(Theme.dim)
                }
            }
            .help("Turn on Nerdpass in System Settings > Privacy & Security > Microphone (capture cards count as one)")
        case let .input(name, symbol, checked):
            RowButton(action: { model.select(name) }) {
                HStack(spacing: 8) {
                    Text(checked ? ">" : " ").foregroundColor(Theme.orange).bold()
                    Image(systemName: symbol).frame(width: 16).foregroundColor(checked ? Theme.orange : Theme.dim)
                    Text(name).foregroundColor(checked ? Theme.orange : Theme.text).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
            }
        case .feedback:
            RowButton(action: { model.openFeedback() }) {
                HStack(spacing: 8) {
                    Text(" ").bold()
                    Image(systemName: "bubble.left.and.text.bubble.right").frame(width: 16).foregroundColor(Theme.dim)
                    Text("feedback")
                    Spacer()
                    Text("github ↗").foregroundColor(Theme.dim)
                }
            }
        case let .alwaysOn(on):
            toggleRow("always_on", symbol: "infinity", on: on, action: model.toggleAlwaysOn)
                .help("Start the sound every time Nerdpass opens (with open_at_login: whenever you log in)")
        case let .openAtLogin(on):
            toggleRow("open_at_login", symbol: "laptopcomputer", on: on, action: model.toggleLogin)
        case .exit:
            RowButton(action: { model.onQuit?() }) {
                HStack(spacing: 8) {
                    Text(" ").bold()
                    Image(systemName: "power").frame(width: 16).foregroundColor(Theme.dim)
                    Text("exit()")
                    Spacer()
                    Text("⌘Q").foregroundColor(Theme.dim)
                }
            }
        }
    }

    private func toggleRow(_ label: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        RowButton(action: action) {
            HStack(spacing: 8) {
                Text(on ? ">" : " ").foregroundColor(Theme.orange).bold()
                Image(systemName: symbol).frame(width: 16).foregroundColor(on ? Theme.orange : Theme.dim)
                Text(label).foregroundColor(on ? Theme.text : Theme.dim)
                Spacer()
            }
        }
    }
}

/// The volume is a straight meter scale: a cream line up to the setting, a red pointer to drag, and a red tint over
/// the last tenth. Click or drag anywhere on it.
struct VolumeScale: View {
    let percent: Int
    let onChange: (Int) -> Void
    @State private var hover = false

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let w = size.width, v = CGFloat(percent) / 100, y: CGFloat = 9
                var base = Path(); base.move(to: CGPoint(x: 0, y: y)); base.addLine(to: CGPoint(x: w, y: y))
                ctx.stroke(base, with: .color(hover ? Theme.dim : Theme.bezel), lineWidth: 1)
                ctx.fill(Path(CGRect(x: w * 0.9, y: y - 1.5, width: w * 0.1, height: 3)), with: .color(Theme.red.opacity(0.35)))
                if v > 0 {
                    var set = Path(); set.move(to: CGPoint(x: 1.5, y: y)); set.addLine(to: CGPoint(x: max(1.5, v * w - 3), y: y))
                    ctx.stroke(set, with: .color(Theme.text), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
                let px = min(w - 4, max(4, v * w))
                var pointer = Path()
                pointer.move(to: CGPoint(x: px, y: y - 2)); pointer.addLine(to: CGPoint(x: px - 4, y: 0))
                pointer.addLine(to: CGPoint(x: px + 4, y: 0)); pointer.closeSubpath()
                ctx.fill(pointer, with: .color(Theme.red))
                for n in [0, 25, 50, 75, 100] {
                    let x = min(w - 7, max(5, CGFloat(n) / 100 * w))
                    ctx.draw(Text("\(n)").font(Theme.scaleFont).foregroundColor(Theme.dim), at: CGPoint(x: x, y: y + 10))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let x = min(max(0, g.location.x), geo.size.width)
                onChange(Int((x / max(1, geo.size.width) * 100).rounded()))
            })
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .onHover { hover = $0 }
        .help("Click or drag to set the volume")
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

/// The menu bar icon: a tiny VU meter in a rounded ring. Stopped, it is a template image (macOS tints it) with the
/// needle at rest. While sound flows the ring glows orange and the needle follows the sound; while Nerdpass waits
/// for the card the ring is blue and the needle sweeps slowly, like a meter self-test.
enum StatusIcon {
    static let size = NSSize(width: 22, height: 22)

    static func image(meter: MeterAnimator, darkMenuBar: Bool) -> NSImage {
        let template = meter.isIdle
        let img = NSImage(size: size, flipped: true) { _ in
            let ink: NSColor = template ? .black : (darkMenuBar ? Theme.creamNS : Theme.darkInkNS)
            let ring: NSColor
            switch meter.mode {
            case .flowing: ring = Theme.orangeNS.withAlphaComponent(0.3 + 0.7 * meter.backlight)
            case .waiting: ring = Theme.blueNS
            case .off: ring = template ? .black : ink.blended(withFraction: meter.backlight, of: Theme.orangeNS) ?? ink
            }
            let frame = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 19, height: 19), xRadius: 5.5, yRadius: 5.5)
            frame.lineWidth = 1.8
            ring.setStroke(); frame.stroke()
            let pivot = NSPoint(x: 11, y: 17)
            func point(_ position: Double, _ r: CGFloat) -> NSPoint {
                let a = (-45 + position * 90) * Double.pi / 180
                return NSPoint(x: pivot.x + CGFloat(sin(a)) * r, y: pivot.y - CGFloat(cos(a)) * r)
            }
            let arc = NSBezierPath()
            arc.move(to: point(0, 9))
            for i in 1...16 { arc.line(to: point(Double(i) / 16, 9)) }
            arc.lineWidth = 1.2
            (meter.mode == .off ? ink : ring).setStroke(); arc.stroke()
            let needle = NSBezierPath()
            needle.move(to: pivot); needle.line(to: point(min(1.08, meter.needle.position), 10))
            needle.lineWidth = 1.4; needle.lineCapStyle = .round
            ink.setStroke(); needle.stroke()
            if !template, meter.needle.position > needleRedZone {
                Theme.redNS.setFill()
                NSBezierPath(ovalIn: NSRect(x: 16.2, y: 7.6, width: 2.8, height: 2.8)).fill()
            }
            return true
        }
        img.isTemplate = template
        return img
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
        // `--snapshot <file.png>` renders the panel to an image and quits (for checking the UI without clicking).
        // With `--demo` it shows made-up inputs with the sound on, and leaves the settings alone (for the README).
        if let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) {
            let shown: AppModel
            if args.contains("--demo") {
                shown = AppModel(backend: SilentBackend(), settings: PassSettings(defaults: UserDefaults(suiteName: "nerdpass-demo")!))
                shown.pass.updateInputs([AudioInput(id: "card", name: "Elgato 4K X"),
                                         AudioInput(id: "mic", name: "MacBook Pro Microphone"),
                                         AudioInput(id: "usb", name: "USB Audio Interface")])
                shown.pass.updateOutputs([AudioOutput(id: "spk", name: "MacBook Pro Speakers"),
                                          AudioOutput(id: "phones", name: "AirPods Pro")])
                shown.pass.start()
                shown.refresh()
                for _ in 0..<60 { shown.stepMeter(1.0 / 30) }
                UserDefaults().removePersistentDomain(forName: "nerdpass-demo")
            } else {
                shown = model
                shown.outputsChanged()
                shown.inputsChanged()
            }
            shown.refresh()
            snapshot(shown, to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }

        if let button = statusItem.button {
            button.image = StatusIcon.image(meter: model.meter, darkMenuBar: isDarkMenuBar)
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
        statusItem.button?.image = StatusIcon.image(meter: model.meter, darkMenuBar: isDarkMenuBar)
        guard iconTimer == nil, !model.meter.isIdle else { return }
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { return }
            let now = Date()
            self.model.stepMeter(now.timeIntervalSince(self.lastTick))
            self.lastTick = now
            self.statusItem.button?.image = StatusIcon.image(meter: self.model.meter, darkMenuBar: self.isDarkMenuBar)
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
