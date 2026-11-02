import XCTest
@testable import PassCore

/// Records what Passthrough asks the audio backend to do.
final class FakeBackend: PassBackend {
    var playing: String?
    var amplitude: Float = -1
    var starts = 0
    var failNext: Error?
    var output: String?
    func start(inputID: String, outputID: String?, amplitude: Float) throws {
        if let e = failNext { failNext = nil; throw e }
        playing = inputID; output = outputID; self.amplitude = amplitude; starts += 1
    }
    func stop() { playing = nil }
    func setAmplitude(_ a: Float) { amplitude = a }
}

struct Boom: LocalizedError { var errorDescription: String? { "device busy" } }

let card = AudioInput(id: "card-1", name: "Elgato 4K X")
let mic = AudioInput(id: "mic-1", name: "MacBook Pro Microphone")
let otherCard = AudioInput(id: "card-2", name: "AVerMedia Live Gamer Ultra")

final class InputTests: XCTestCase {
    func testRecognizesCaptureCards() {
        for name in ["Elgato 4K X", "Game Capture HD60 S+", "Cam Link 4K", "AVerMedia Live Gamer 4K", "USB3.0 Capture",
                     "Magewell USB Capture HDMI", "UltraStudio Recorder 3G", "USB Video"] {
            XCTAssertTrue(looksLikeCaptureCard(name), name)
        }
        for name in ["MacBook Pro Microphone", "Shure MV7", "Scarlett 2i2 USB", "AirPods Pro", "BlackHole 2ch"] {
            XCTAssertFalse(looksLikeCaptureCard(name), name)
        }
    }

    func testPicksFirstCaptureCardWhenNothingIsSaved() {
        XCTAssertEqual(chooseInput(from: [mic, card, otherCard], savedID: nil, savedName: nil), card)
        XCTAssertNil(chooseInput(from: [mic], savedID: nil, savedName: nil), "never falls back to a microphone")
    }

    func testPrefersTheSavedInputByIDThenName() {
        XCTAssertEqual(chooseInput(from: [card, mic], savedID: "mic-1", savedName: "MacBook Pro Microphone"), mic)
        let moved = AudioInput(id: "card-1-other-port", name: "Elgato 4K X")
        XCTAssertEqual(chooseInput(from: [mic, moved], savedID: "card-1", savedName: "Elgato 4K X"), moved)
    }

    func testWaitsForAMissingSavedInputInsteadOfSwitching() {
        XCTAssertNil(chooseInput(from: [mic, otherCard], savedID: "card-1", savedName: "Elgato 4K X"))
    }
}

final class SettingsTests: XCTestCase {
    func testDefaultsAndClamping() {
        let s = PassSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertEqual(s.volumePercent, 80)
        XCTAssertTrue(s.alwaysOn, "always on by default")
        XCTAssertFalse(s.didDefaultLogin)
        XCTAssertNil(s.inputID)
        s.volumePercent = 140
        XCTAssertEqual(s.volumePercent, 100)
        s.volumePercent = -5
        XCTAssertEqual(s.volumePercent, 0)
    }

    func testCubicVolumeCurve() {
        XCTAssertEqual(amplitude(percent: 100), 1)
        XCTAssertEqual(amplitude(percent: 0), 0)
        XCTAssertEqual(amplitude(percent: 50), 0.125, accuracy: 0.0001)
        XCTAssertEqual(amplitude(percent: 250), 1)
    }
}

final class PassthroughTests: XCTestCase {
    var backend: FakeBackend!
    var settings: PassSettings!
    var pass: Passthrough!

    override func setUp() {
        backend = FakeBackend()
        settings = PassSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        pass = Passthrough(backend: backend, settings: settings)
    }

    func testStartPlaysTheCaptureCardAndRemembersIt() {
        pass.updateInputs([mic, card])
        pass.start()
        XCTAssertEqual(pass.state, .flowing(card))
        XCTAssertEqual(backend.playing, "card-1")
        XCTAssertEqual(backend.amplitude, amplitude(percent: 80), "80% by default")
        XCTAssertEqual(settings.inputID, "card-1")
    }

    func testStopAndToggle() {
        pass.updateInputs([card])
        pass.toggle()
        XCTAssertTrue(pass.state.isOn)
        pass.toggle()
        XCTAssertEqual(pass.state, .stopped)
        XCTAssertNil(backend.playing)
    }

    func testVolumeAppliesWhilePlayingAndAtTheNextStart() {
        pass.setVolume(50)
        pass.updateInputs([card])
        pass.start()
        XCTAssertEqual(backend.amplitude, 0.125, accuracy: 0.0001)
        pass.setVolume(100)
        XCTAssertEqual(backend.amplitude, 1)
        XCTAssertEqual(pass.volumePercent, 100)
    }

    func testUnpluggingWaitsAndReplugResumes() {
        pass.updateInputs([card, mic])
        pass.start()
        pass.updateInputs([mic])
        XCTAssertEqual(pass.state, .waiting("Elgato 4K X"))
        XCTAssertNil(backend.playing, "never switches to the microphone")
        pass.updateInputs([mic, card])
        XCTAssertEqual(pass.state, .flowing(card))
        XCTAssertEqual(backend.playing, "card-1")
    }

    func testStartWithNoCardWaitsForOne() {
        pass.updateInputs([mic])
        pass.start()
        XCTAssertEqual(pass.state, .waiting("a capture card"))
        pass.updateInputs([mic, otherCard])
        XCTAssertEqual(pass.state, .flowing(otherCard))
    }

    func testSelectingAnInputSwitchesToIt() {
        pass.updateInputs([card, mic])
        pass.start()
        pass.select(mic)
        XCTAssertEqual(pass.state, .flowing(mic))
        XCTAssertEqual(backend.playing, "mic-1")
        XCTAssertEqual(settings.inputName, "MacBook Pro Microphone")
    }

    func testStartFailureIsShownAndRetried() {
        pass.updateInputs([card])
        backend.failNext = Boom()
        pass.start()
        XCTAssertEqual(pass.state, .failed("can't open Elgato 4K X: device busy"))
        pass.start()
        XCTAssertEqual(pass.state, .flowing(card))
    }

    func testAlwaysOnStartsAtLaunch() {
        pass.updateInputs([card])
        pass.launch()
        XCTAssertEqual(pass.state, .flowing(card), "always on is the default")
        pass.shutdown()
        XCTAssertNil(backend.playing)
    }

    func testAlwaysOffStaysStoppedAtLaunch() {
        pass.setAlwaysOn(false)
        XCTAssertFalse(settings.alwaysOn)
        pass.updateInputs([card])
        pass.launch()
        XCTAssertEqual(pass.state, .stopped)
    }

    func testAlwaysOnWaitsForTheCardAtLaunch() {
        pass.updateInputs([mic])
        pass.launch()
        XCTAssertEqual(pass.state, .waiting("a capture card"))
        pass.updateInputs([mic, card])
        XCTAssertEqual(pass.state, .flowing(card))
    }

    func testFailStopsTheSound() {
        pass.updateInputs([card])
        pass.start()
        pass.fail("microphone access is off")
        XCTAssertEqual(pass.state, .failed("microphone access is off"))
        XCTAssertNil(backend.playing)
    }

    func testOnChangeFires() {
        var count = 0
        pass.onChange = { count += 1 }
        pass.updateInputs([card])
        pass.start()
        pass.setVolume(30)
        pass.stop()
        XCTAssertEqual(count, 4)
    }
}

final class MenuTests: XCTestCase {
    func testLayout() {
        let entries = menuEntries(for: MenuState(flow: .flowing(card), inputs: [mic, card], selectedID: "card-1",
                                                 volumePercent: 80, alwaysOn: true, openAtLogin: true))
        XCTAssertEqual(entries, [
            .flow(status: "Elgato 4K X → speakers", on: true, enabled: true),
            .volume(percent: 80),
            .separator,
            .header("// input"),
            .input(name: "Elgato 4K X", symbol: "tv", checked: true),
            .input(name: "MacBook Pro Microphone", symbol: "mic", checked: false),
            .header("// output"),
            .output(name: nil, symbol: "speaker.wave.2", checked: true),
            .separator,
            .look(.needle),
            .feedback,
            .alwaysOn(on: true),
            .openAtLogin(on: true),
            .exit,
        ])
    }

    func testNoInputsAndDeniedAccess() {
        let entries = menuEntries(for: MenuState(flow: .stopped, inputs: [], selectedID: nil, volumePercent: 100,
                                                 alwaysOn: false, openAtLogin: false, accessDenied: true))
        XCTAssertEqual(entries[0], .flow(status: "stopped", on: false, enabled: false))
        XCTAssertTrue(entries.contains(.permission))
        XCTAssertTrue(entries.contains(.noInputs))
    }

    func testStatusLines() {
        XCTAssertEqual(statusLine(.waiting("Elgato 4K X")), "waiting for Elgato 4K X…")
        XCTAssertEqual(statusLine(.failed("oops")), "oops")
    }
}

final class MeterTests: XCTestCase {
    func testNeedleScale() {
        XCTAssertEqual(needleTarget(rmsDecibels: -120), 0)
        XCTAssertEqual(needleTarget(rmsDecibels: -60), 0, accuracy: 0.001, "rests below the floor")
        XCTAssertGreaterThan(needleTarget(rmsDecibels: -45), 0.2, "quiet sound still moves the needle")
        XCTAssertEqual(needleTarget(rmsDecibels: -24.001), needleTarget(rmsDecibels: -24), accuracy: 0.001, "no jump at the knee")
        XCTAssertEqual(needleTarget(rmsDecibels: -24), 14.0 / 23, accuracy: 0.001, "the loud end is a real VU scale")
        XCTAssertEqual(needleTarget(rmsDecibels: -18), needleRedZone, accuracy: 0.001, "0 VU is -18 dBFS")
        XCTAssertEqual(needleTarget(rmsDecibels: -15), 1, accuracy: 0.001)
        XCTAssertEqual(needleTarget(rmsDecibels: 0), 1.08, "pinned just past +3")
    }

    func testRMS() {
        let full = [Float](repeating: 1, count: 64), half = [Float](repeating: 0.5, count: 64), zero = [Float](repeating: 0, count: 8)
        full.withUnsafeBufferPointer { XCTAssertEqual(rmsDecibels($0), 0, accuracy: 0.01) }
        half.withUnsafeBufferPointer { XCTAssertEqual(rmsDecibels($0), -6.02, accuracy: 0.01) }
        zero.withUnsafeBufferPointer { XCTAssertEqual(rmsDecibels($0), -120) }
    }

    func testBallisticsReachTheLevelInAboutAThirdOfASecond() {
        var n = NeedleBallistics()
        n.step(toward: 0.6, dt: 0.15)
        XCTAssertGreaterThan(n.position, 0.3)
        n.step(toward: 0.6, dt: 0.6)
        XCTAssertEqual(n.position, 0.6, accuracy: 0.02)
    }

    func testStartKicksThenSettles() {
        var m = MeterAnimator()
        m.setMode(.flowing)
        var peak = 0.0
        for _ in 0..<20 { m.step(dt: 0.02, level: 0.4); peak = max(peak, m.needle.position) }
        XCTAssertGreaterThan(peak, 0.85, "kicks toward +3")
        for _ in 0..<60 { m.step(dt: 0.02, level: 0.4) }
        XCTAssertEqual(m.needle.position, 0.4, accuracy: 0.03)
        XCTAssertEqual(m.backlight, 1)
    }

    func testStopDropsBouncesAndGoesIdle() {
        var m = MeterAnimator()
        m.setMode(.flowing)
        for _ in 0..<60 { m.step(dt: 0.02, level: 0.7) }
        m.setMode(.off)
        var bounced = false
        for _ in 0..<100 { m.step(dt: 0.02, level: 0.7); if m.needle.velocity > 0 { bounced = true } }
        XCTAssertTrue(bounced, "the needle bounces once off its stop")
        XCTAssertTrue(m.isIdle)
    }

    func testWarmUpFlickers() {
        XCTAssertLessThan(MeterAnimator.warmUpCurve(0.08), MeterAnimator.warmUpCurve(0.05))
        XCTAssertEqual(MeterAnimator.warmUpCurve(1), 1)
    }

    func testWaitingSweeps() {
        var m = MeterAnimator()
        m.setMode(.waiting)
        var high = 0.0
        for _ in 0..<150 { m.step(dt: 0.02, level: 0); high = max(high, m.needle.position) }
        XCTAssertGreaterThan(high, 0.8)
        XCTAssertFalse(m.isIdle)
    }
}

final class MeterTimingTests: XCTestCase {
    /// Settles on `level`, then jumps to `to` and returns how far the needle got in `seconds`.
    private func travel(from level: Double, to target: Double, seconds: Double) -> Double {
        var m = MeterAnimator()
        m.setMode(.flowing)
        for _ in 0..<120 { m.step(dt: 1.0 / 30, level: level) }
        let start = m.needle.position
        for _ in 0..<Int(seconds * 30) { m.step(dt: 1.0 / 30, level: target) }
        return abs(m.needle.position - start) / abs(target - start)
    }

    func testRisesFastAndFallsSlowly() {
        XCTAssertGreaterThan(travel(from: 0.2, to: 0.8, seconds: 0.1), 0.7, "a hit shows within 100 ms")
        XCTAssertLessThan(travel(from: 0.8, to: 0.2, seconds: 0.1), 0.35, "a fade lingers")
        XCTAssertGreaterThan(travel(from: 0.8, to: 0.2, seconds: 1.0), 0.95, "and still comes down within a second")
    }
}

let speakers = AudioOutput(id: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
let phones = AudioOutput(id: "phones-1", name: "AirPods Pro")

final class OutputTests: XCTestCase {
    var backend: FakeBackend!
    var settings: PassSettings!
    var pass: Passthrough!

    override func setUp() {
        backend = FakeBackend()
        settings = PassSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        pass = Passthrough(backend: backend, settings: settings)
        pass.updateInputs([card])
        pass.updateOutputs([speakers, phones])
    }

    func testPlaysToTheDefaultOutputUntilOneIsPicked() {
        pass.start()
        XCTAssertNil(backend.output)
        XCTAssertNil(pass.selectedOutput)
    }

    func testPickingAnOutputMovesPlayingSoundThere() {
        pass.start()
        pass.selectOutput(phones)
        XCTAssertEqual(backend.output, "phones-1")
        XCTAssertEqual(pass.state, .flowing(card))
        XCTAssertEqual(settings.outputName, "AirPods Pro")
        pass.selectOutput(nil)
        XCTAssertNil(backend.output)
        XCTAssertNil(settings.outputID)
    }

    func testPickingAnOutputWhileStoppedDoesNotStart() {
        pass.selectOutput(phones)
        XCTAssertEqual(pass.state, .stopped)
        XCTAssertNil(backend.playing)
        pass.start()
        XCTAssertEqual(backend.output, "phones-1")
    }

    func testFallsBackToDefaultAndReturnsWhenThePickedOutputComesBack() {
        pass.selectOutput(phones)
        pass.start()
        let starts = backend.starts
        pass.updateOutputs([speakers])
        XCTAssertNil(backend.output, "phones gone: default output")
        XCTAssertEqual(pass.state, .flowing(card))
        pass.updateOutputs([speakers, phones])
        XCTAssertEqual(backend.output, "phones-1", "back on the phones")
        XCTAssertEqual(backend.starts, starts + 2)
        pass.updateOutputs([speakers, phones])
        XCTAssertEqual(backend.starts, starts + 2, "no restart when nothing changed")
    }

    func testFollowsTheDefaultOutputOnlyWhenPlayingToIt() {
        pass.start()
        let starts = backend.starts
        pass.defaultOutputChanged()
        XCTAssertEqual(backend.starts, starts + 1, "restarts on the new default")
        pass.selectOutput(phones)
        pass.defaultOutputChanged()
        XCTAssertEqual(backend.starts, starts + 2, "only the switch to the phones, not the default change")
    }

    func testOutputSymbols() {
        XCTAssertEqual(outputSymbol("AirPods Pro"), "headphones")
        XCTAssertEqual(outputSymbol("External Headphones"), "headphones")
        XCTAssertEqual(outputSymbol("LG HDR 4K (HDMI)"), "display")
        XCTAssertEqual(outputSymbol("MacBook Pro Speakers"), "hifispeaker")
    }

    func testMenuListsOutputsAndStatusNamesThePickedOne() {
        let entries = menuEntries(for: MenuState(flow: .flowing(card), inputs: [card], selectedID: "card-1",
                                                 outputs: [speakers, phones], selectedOutputID: "phones-1",
                                                 volumePercent: 80, alwaysOn: true, openAtLogin: true))
        XCTAssertEqual(entries[0], .flow(status: "Elgato 4K X → AirPods Pro", on: true, enabled: true))
        XCTAssertTrue(entries.contains(.output(name: nil, symbol: "speaker.wave.2", checked: false)))
        XCTAssertTrue(entries.contains(.output(name: "AirPods Pro", symbol: "headphones", checked: true)))
    }
}

final class LookTests: XCTestCase {
    func testNeedleByDefaultAndRemembered() {
        let settings = PassSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertEqual(settings.look, .needle)
        let pass = Passthrough(backend: FakeBackend(), settings: settings)
        var changes = 0
        pass.onChange = { changes += 1 }
        pass.setLook(.tally)
        XCTAssertEqual(settings.look, .tally)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(menuEntries(for: MenuState(flow: .stopped, inputs: [], selectedID: nil, volumePercent: 80,
                                                  look: .tally, alwaysOn: true, openAtLogin: true)).filter {
            if case .look = $0 { return true }; return false
        }, [.look(.tally)])
    }

    func testButtonLabels() {
        XCTAssertEqual(flowButtonLabel(look: .needle, on: false), "start()")
        XCTAssertEqual(flowButtonLabel(look: .phosphor, on: true), "stop()")
        XCTAssertEqual(flowButtonLabel(look: .tally, on: false), "take()")
        XCTAssertEqual(flowButtonLabel(look: .tally, on: true), "cut()")
    }

    func testClock() {
        XCTAssertEqual(clockString(0), "00:00:00")
        XCTAssertEqual(clockString(764), "00:12:44")
        XCTAssertEqual(clockString(3 * 3600 + 5), "03:00:05")
    }

    func testDecibelScaleMatchesTheVolumeCurve() {
        XCTAssertEqual(volumePercent(forDecibels: 0), 100, accuracy: 0.001)
        XCTAssertEqual(volumePercent(forDecibels: -6), 79.4, accuracy: 0.1)
        XCTAssertEqual(Double(amplitude(percent: Int(volumePercent(forDecibels: -12).rounded()))), 0.25, accuracy: 0.01)
    }
}
