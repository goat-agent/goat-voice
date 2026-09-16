import Foundation

public enum KeyboardModifier: String, Codable, Sendable, Hashable, CaseIterable {
    case leftOption, rightOption, leftControl, rightControl
    case leftCommand, rightCommand, leftShift, rightShift
    case option, control, command, shift
    case function

    public var keyCodes: Set<UInt16> {
        switch self {
        case .leftOption: return [0x3A]
        case .rightOption: return [0x3D]
        case .leftControl: return [0x3B]
        case .rightControl: return [0x3E]
        case .leftCommand: return [0x37]
        case .rightCommand: return [0x36]
        case .leftShift: return [0x38]
        case .rightShift: return [0x3C]
        case .option: return [0x3A, 0x3D]
        case .control: return [0x3B, 0x3E]
        case .command: return [0x37, 0x36]
        case .shift: return [0x38, 0x3C]
        case .function: return [0x3F]
        }
    }

    public static func sideSpecific(forKeyCode keyCode: UInt16) -> KeyboardModifier? {
        for modifier in KeyboardModifier.allCases where modifier.isSideSpecific {
            if modifier.keyCodes.contains(keyCode) { return modifier }
        }
        return nil
    }

    public static func eventModifier(forKeyCode keyCode: UInt16) -> KeyboardModifier? {
        if let sideSpecific = sideSpecific(forKeyCode: keyCode) { return sideSpecific }
        return KeyboardModifier.function.keyCodes.contains(keyCode) ? .function : nil
    }

    public var isSideSpecific: Bool {
        switch self {
        case .leftOption, .rightOption, .leftControl, .rightControl,
             .leftCommand, .rightCommand, .leftShift, .rightShift:
            return true
        case .option, .control, .command, .shift, .function:
            return false
        }
    }

    public var generic: KeyboardModifier {
        switch self {
        case .leftOption, .rightOption: return .option
        case .leftControl, .rightControl: return .control
        case .leftCommand, .rightCommand: return .command
        case .leftShift, .rightShift: return .shift
        case .function, .option, .control, .command, .shift: return self
        }
    }
}

public enum TriggerSpec: Codable, Equatable, Sendable {
    case modifier(KeyboardModifier)
    case chord(keyCode: UInt16, modifiers: Set<KeyboardModifier>)

    public static let `default` = TriggerSpec.modifier(.rightOption)

    public var triggerKeyCodes: Set<UInt16> {
        switch self {
        case .modifier(let modifier):
            return modifier.keyCodes
        case .chord(let keyCode, let modifiers):
            return modifiers.reduce(into: Set([keyCode])) { $0.formUnion($1.keyCodes) }
        }
    }

    public var displayName: String {
        switch self {
        case .modifier(let modifier):
            switch modifier {
            case .rightOption: return "Right Option"
            case .leftOption: return "Left Option"
            case .rightControl: return "Right Control"
            case .leftControl: return "Left Control"
            case .rightCommand: return "Right Command"
            case .leftCommand: return "Left Command"
            case .rightShift: return "Right Shift"
            case .leftShift: return "Left Shift"
            case .option: return "Option"
            case .control: return "Control"
            case .command: return "Command"
            case .shift: return "Shift"
            case .function: return "Fn"
            }
        case .chord(let keyCode, let modifiers):
            var symbols = ""
            if modifiers.contains(.control) { symbols += "⌃" }
            if modifiers.contains(.option) { symbols += "⌥" }
            if modifiers.contains(.shift) { symbols += "⇧" }
            if modifiers.contains(.command) { symbols += "⌘" }
            return symbols + (KeyCodeName.name(for: keyCode) ?? "Key \(keyCode)")
        }
    }
}

public enum KeyCodeName {
    public static func name(for keyCode: UInt16) -> String? {
        names[keyCode]
    }

    private static let names: [UInt16: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F",
        0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L",
        0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z", 0x31: "Space", 0x24: "Return", 0x35: "Esc",
        0x30: "Tab", 0x33: "Delete", 0x7A: "F1", 0x78: "F2", 0x63: "F3",
        0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13",
        0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18",
        0x50: "F19", 0x5A: "F20",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
        0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
    ]
}

public enum InputEvent: Sendable, Equatable {
    case keyDown(keyCode: UInt16, modifiers: Set<KeyboardModifier>, isRepeat: Bool)
    case keyUp(keyCode: UInt16, modifiers: Set<KeyboardModifier>)
    case modifierDown(KeyboardModifier, keyCode: UInt16)
    case modifierUp(KeyboardModifier, keyCode: UInt16)
    case pointerDown
    case pointerDrag
    case scrollWheel
    case tapDisabledByTimeout
}

public enum TriggerEffect: Sendable, Equatable {
    case began
    case ended
    case cancelledByExtraKey
    case cancelledByEscape
    case tapDisabled
}
