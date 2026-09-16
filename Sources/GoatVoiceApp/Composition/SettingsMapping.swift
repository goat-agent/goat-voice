import Foundation
import GoatVoicePlatform

extension TriggerSpec {
    init(shortcut: TriggerShortcut) {
        switch shortcut.kind {
        case .modifierOnly(let key):
            self = .modifier(key.keyboardModifier)
        case .chord(let chord):
            self = .chord(keyCode: chord.keyCode, modifiers: chord.modifiers.keyboardModifiers)
        }
    }
}

extension TriggerShortcut {
    init(spec: TriggerSpec) {
        switch spec {
        case .modifier(let modifier):
            self.init(kind: .modifierOnly(ModifierKey(keyboardModifier: modifier)))
        case .chord(let keyCode, let modifiers):
            self.init(kind: .chord(Chord(
                keyCode: keyCode, modifiers: Chord.Modifiers(keyboardModifiers: modifiers))))
        }
    }
}

extension ModifierKey {
    var keyboardModifier: KeyboardModifier {
        switch (base, side) {
        case (.control, .left): return .leftControl
        case (.control, .right): return .rightControl
        case (.control, .either): return .control
        case (.option, .left): return .leftOption
        case (.option, .right): return .rightOption
        case (.option, .either): return .option
        case (.shift, .left): return .leftShift
        case (.shift, .right): return .rightShift
        case (.shift, .either): return .shift
        case (.command, .left): return .leftCommand
        case (.command, .right): return .rightCommand
        case (.command, .either): return .command
        case (.function, _): return .function
        }
    }

    init(keyboardModifier: KeyboardModifier) {
        switch keyboardModifier {
        case .leftOption: self.init(base: .option, side: .left)
        case .rightOption: self.init(base: .option, side: .right)
        case .leftControl: self.init(base: .control, side: .left)
        case .rightControl: self.init(base: .control, side: .right)
        case .leftCommand: self.init(base: .command, side: .left)
        case .rightCommand: self.init(base: .command, side: .right)
        case .leftShift: self.init(base: .shift, side: .left)
        case .rightShift: self.init(base: .shift, side: .right)
        case .option: self.init(base: .option, side: .either)
        case .control: self.init(base: .control, side: .either)
        case .command: self.init(base: .command, side: .either)
        case .shift: self.init(base: .shift, side: .either)
        case .function: self.init(base: .function, side: .either)
        }
    }
}

extension Chord.Modifiers {
    var keyboardModifiers: Set<KeyboardModifier> {
        var result = Set<KeyboardModifier>()
        if contains(.control) { result.insert(.control) }
        if contains(.option) { result.insert(.option) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.command) { result.insert(.command) }
        if contains(.function) { result.insert(.function) }
        return result
    }

    init(keyboardModifiers: Set<KeyboardModifier>) {
        self.init()
        for modifier in keyboardModifiers {
            switch modifier.generic {
            case .control: insert(.control)
            case .option: insert(.option)
            case .shift: insert(.shift)
            case .command: insert(.command)
            case .function: insert(.function)
            default: break
            }
        }
    }
}

extension MicrophoneSelection {
    var selectedUID: String? {
        switch self {
        case .systemDefault: return nil
        case .pinned(let deviceUID, _): return deviceUID
        }
    }

    init(pinnedUID: String?, label: String?) {
        if let pinnedUID {
            self = .pinned(deviceUID: pinnedUID, label: label ?? pinnedUID)
        } else {
            self = .systemDefault
        }
    }
}

extension PermissionState {
    init(microphonePermission: MicrophonePermission) {
        switch microphonePermission {
        case .granted: self = .allowed
        case .denied, .restricted: self = .denied
        case .notDetermined: self = .notDetermined
        }
    }

    init(accessibilityPermission: AccessibilityPermission) {
        switch accessibilityPermission {
        case .trusted: self = .allowed
        case .untrusted: self = .notDetermined
        }
    }
}
