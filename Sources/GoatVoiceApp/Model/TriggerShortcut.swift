import Carbon
import Foundation

struct TriggerShortcut: Equatable, Codable, Sendable {
    enum Kind: Equatable, Codable, Sendable {
        case modifierOnly(ModifierKey)
        case chord(Chord)
    }

    var kind: Kind

    static let `default` = TriggerShortcut(kind: .modifierOnly(ModifierKey(base: .option, side: .right)))
}

struct ModifierKey: Equatable, Codable, Sendable {
    enum Base: String, Codable, Sendable, CaseIterable {
        case control
        case option
        case shift
        case command
        case function
    }

    enum Side: String, Codable, Sendable {
        case left
        case right
        case either
    }

    var base: Base
    var side: Side
}

struct Chord: Equatable, Codable, Sendable {
    struct Modifiers: OptionSet, Codable, Sendable {
        let rawValue: Int

        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
        static let function = Modifiers(rawValue: 1 << 4)
    }

    var keyCode: UInt16
    var modifiers: Modifiers
}

extension TriggerShortcut {
    var displayName: String {
        switch kind {
        case .modifierOnly(let key):
            return key.displayName
        case .chord(let chord):
            return chord.displayName
        }
    }
}

extension ModifierKey {
    var displayName: String {
        switch (base, side) {
        case (.function, _):
            return "Fn"
        case (_, .either):
            return base.baseName
        default:
            return "\(side == .left ? "Left" : "Right") \(base.baseName)"
        }
    }
}

extension ModifierKey.Base {
    var baseName: String {
        switch self {
        case .control: return "Control"
        case .option: return "Option"
        case .shift: return "Shift"
        case .command: return "Command"
        case .function: return "Fn"
        }
    }

    var symbol: String {
        switch self {
        case .control: return "\u{2303}"
        case .option: return "\u{2325}"
        case .shift: return "\u{21E7}"
        case .command: return "\u{2318}"
        case .function: return "Fn"
        }
    }
}

extension Chord {
    var displayName: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += ModifierKey.Base.control.symbol }
        if modifiers.contains(.option) { symbols += ModifierKey.Base.option.symbol }
        if modifiers.contains(.shift) { symbols += ModifierKey.Base.shift.symbol }
        if modifiers.contains(.command) { symbols += ModifierKey.Base.command.symbol }
        if modifiers.contains(.function) { symbols += ModifierKey.Base.function.symbol }
        return symbols + KeyName.name(for: keyCode)
    }
}

enum KeyName {
    static func name(for keyCode: UInt16) -> String {
        if let named = table[keyCode] {
            return named
        }
        if let translated = translatedName(for: keyCode) {
            return translated
        }
        return "Key \(keyCode)"
    }

    private static func translatedName(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
            .takeUnretainedValue(),
            let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let base = buffer.baseAddress else { return nil }
            let layout = UnsafeRawPointer(base).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                0,
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }

    private static let table: [UInt16: String] = [
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Escape",
        76: "Enter",
        96: "F5",
        97: "F6",
        98: "F7",
        99: "F3",
        100: "F8",
        101: "F9",
        103: "F11",
        105: "F13",
        106: "F16",
        107: "F14",
        109: "F10",
        111: "F12",
        113: "F15",
        115: "Home",
        116: "Page Up",
        117: "Forward Delete",
        118: "F4",
        119: "End",
        120: "F2",
        121: "Page Down",
        122: "F1",
        123: "\u{2190}",
        124: "\u{2192}",
        125: "\u{2193}",
        126: "\u{2191}",
    ]
}
