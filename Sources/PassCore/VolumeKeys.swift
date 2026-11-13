import Foundation

/// The keyboard's volume keys, which Nerdpass takes over while Shift is held.
public enum VolumeKey: Equatable {
    case up, down, mute
}

/// One volume key event: which key, pressed or released, and whether it is a key repeat.
public struct VolumeKeyEvent: Equatable {
    public var key: VolumeKey
    public var isDown: Bool
    public var isRepeat: Bool
    public init(key: VolumeKey, isDown: Bool, isRepeat: Bool) { self.key = key; self.isDown = isDown; self.isRepeat = isRepeat }
}

/// Reads a media key event's `data1` (macOS sends media keys as system-defined events of subtype 8): the key type in
/// the high 16 bits (NX_KEYTYPE_SOUND_UP 0, SOUND_DOWN 1, MUTE 7), then the state (0xA pressed, 0xB released) and a
/// repeat bit. Nil for any other media key (brightness, play, ...).
public func volumeKeyEvent(data1: Int) -> VolumeKeyEvent? {
    let type = (data1 & 0xFFFF_0000) >> 16, flags = data1 & 0xFFFF, state = (flags & 0xFF00) >> 8
    let key: VolumeKey
    switch type {
    case 0: key = .up
    case 1: key = .down
    case 7: key = .mute
    default: return nil
    }
    guard state == 0xA || state == 0xB else { return nil }
    return VolumeKeyEvent(key: key, isDown: state == 0xA, isRepeat: flags & 0x1 == 1)
}

/// Each press of Shift+Volume Up or Down moves the volume this many percent (40 presses from silence to 200%).
public let volumeKeyStep = 5

/// The volume after one Shift+Volume Up or Down press: snapped to the step grid, between 0 and 200%.
public func steppedVolume(_ percent: Int, _ key: VolumeKey) -> Int {
    switch key {
    case .up: return min(PassSettings.maxPercent, (percent / volumeKeyStep + 1) * volumeKeyStep)
    case .down: return max(0, ((percent + volumeKeyStep - 1) / volumeKeyStep - 1) * volumeKeyStep)
    case .mute: return percent
    }
}
