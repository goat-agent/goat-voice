import Foundation

public struct ModifierTransition: Equatable, Sendable {
    public let modifier: KeyboardModifier
    public let isDown: Bool

    public init?(keyCode: UInt16, rawFlags: UInt64) {
        guard let modifier = KeyboardModifier.eventModifier(forKeyCode: keyCode) else { return nil }
        self.modifier = modifier
        self.isDown = Self.isDown(modifier, rawFlags: rawFlags)
    }

    private static func isDown(_ modifier: KeyboardModifier, rawFlags: UInt64) -> Bool {
        switch modifier {
        case .leftControl:
            return sided(rawFlags, side: DeviceMask.leftControl, family: DeviceMask.control, generic: GenericMask.control)
        case .rightControl:
            return sided(rawFlags, side: DeviceMask.rightControl, family: DeviceMask.control, generic: GenericMask.control)
        case .leftShift:
            return sided(rawFlags, side: DeviceMask.leftShift, family: DeviceMask.shift, generic: GenericMask.shift)
        case .rightShift:
            return sided(rawFlags, side: DeviceMask.rightShift, family: DeviceMask.shift, generic: GenericMask.shift)
        case .leftCommand:
            return sided(rawFlags, side: DeviceMask.leftCommand, family: DeviceMask.command, generic: GenericMask.command)
        case .rightCommand:
            return sided(rawFlags, side: DeviceMask.rightCommand, family: DeviceMask.command, generic: GenericMask.command)
        case .leftOption:
            return sided(rawFlags, side: DeviceMask.leftOption, family: DeviceMask.option, generic: GenericMask.option)
        case .rightOption:
            return sided(rawFlags, side: DeviceMask.rightOption, family: DeviceMask.option, generic: GenericMask.option)
        case .control:
            return rawFlags & GenericMask.control != 0
        case .option:
            return rawFlags & GenericMask.option != 0
        case .shift:
            return rawFlags & GenericMask.shift != 0
        case .command:
            return rawFlags & GenericMask.command != 0
        case .function:
            return rawFlags & GenericMask.secondaryFunction != 0
        }
    }

    private static func sided(_ rawFlags: UInt64, side: UInt64, family: UInt64, generic: UInt64) -> Bool {
        if rawFlags & family != 0 {
            return rawFlags & side != 0
        }
        return rawFlags & generic != 0
    }
}

private enum DeviceMask {
    static let leftControl: UInt64 = 0x0000_0001
    static let leftShift: UInt64 = 0x0000_0002
    static let rightShift: UInt64 = 0x0000_0004
    static let leftCommand: UInt64 = 0x0000_0008
    static let rightCommand: UInt64 = 0x0000_0010
    static let leftOption: UInt64 = 0x0000_0020
    static let rightOption: UInt64 = 0x0000_0040
    static let rightControl: UInt64 = 0x0000_2000
    static let control = leftControl | rightControl
    static let shift = leftShift | rightShift
    static let command = leftCommand | rightCommand
    static let option = leftOption | rightOption
}

private enum GenericMask {
    static let shift: UInt64 = 0x0002_0000
    static let control: UInt64 = 0x0004_0000
    static let option: UInt64 = 0x0008_0000
    static let command: UInt64 = 0x0010_0000
    static let secondaryFunction: UInt64 = 0x0080_0000
}
