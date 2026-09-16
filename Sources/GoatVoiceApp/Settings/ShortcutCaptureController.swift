import AppKit
import Foundation
import GoatVoicePlatform

final class ShortcutCaptureController {
    enum Outcome {
        case committed(TriggerShortcut)
        case cancelled
    }

    var onOutcome: ((Outcome) -> Void)?
    var onPreviewChange: ((String?) -> Void)?

    private var monitor: Any?
    private var heldModifiers: [UInt16: ModifierKey] = [:]
    private var holdOrder: [UInt16] = []
    private(set) var isCapturing = false

    func start() {
        stop()
        heldModifiers = [:]
        holdOrder = []
        isCapturing = true
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            guard let self, self.isCapturing else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        isCapturing = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    func cancel() {
        finish(.cancelled)
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 {
                finish(.cancelled)
                return nil
            }
            if event.keyCode == 48,
               event.modifierFlags.intersection([.control, .option, .command]).isEmpty {
                return event
            }
            if KeyboardModifier.eventModifier(forKeyCode: event.keyCode) != nil {
                return nil
            }
            let modifiers = Chord.Modifiers(event.modifierFlags)
            finish(.committed(TriggerShortcut(
                kind: .chord(Chord(keyCode: event.keyCode, modifiers: modifiers))
            )))
            return nil
        case .flagsChanged:
            trackModifier(event)
            return nil
        default:
            return event
        }
    }

    private func trackModifier(_ event: NSEvent) {
        guard let transition = ModifierTransition(
            keyCode: event.keyCode, rawFlags: UInt64(event.modifierFlags.rawValue))
        else { return }
        let key = ModifierKey(keyboardModifier: transition.modifier)
        if transition.isDown {
            if heldModifiers[event.keyCode] == nil {
                heldModifiers[event.keyCode] = key
                holdOrder.append(event.keyCode)
            }
            onPreviewChange?(previewText)
        } else {
            heldModifiers.removeValue(forKey: event.keyCode)
            holdOrder.removeAll { $0 == event.keyCode }
            if heldModifiers.isEmpty {
                finish(.committed(TriggerShortcut(kind: .modifierOnly(key))))
            } else {
                onPreviewChange?(previewText)
            }
        }
    }

    private var previewText: String {
        holdOrder.compactMap { heldModifiers[$0]?.displayName }.joined(separator: " + ")
    }

    private func finish(_ outcome: Outcome) {
        stop()
        onOutcome?(outcome)
    }
}

extension Chord.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var result = Chord.Modifiers()
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.function) { result.insert(.function) }
        self = result
    }
}
