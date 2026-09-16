import Foundation

public struct BoundarySpacing: Sendable, Equatable {
    public var leadingSpace: Bool
    public var trailingSpace: Bool

    public static let none = BoundarySpacing(leadingSpace: false, trailingSpace: false)

    public init(leadingSpace: Bool, trailingSpace: Bool) {
        self.leadingSpace = leadingSpace
        self.trailingSpace = trailingSpace
    }
}

public enum TextNormalization {
    public static func normalize(_ raw: String) -> String {
        let unified = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var scalars = unified.unicodeScalars.filter(isDeliverable)
        while scalars.first?.properties.isWhitespace == true {
            scalars.removeFirst()
        }
        while scalars.last?.properties.isWhitespace == true {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    public static func spacing(inserting normalized: String,
                               before left: Character?,
                               after right: Character?) -> BoundarySpacing {
        guard let first = normalized.first, let last = normalized.last else {
            return .none
        }
        return BoundarySpacing(
            leadingSpace: needsSpace(between: left.map(classify), and: classify(first)),
            trailingSpace: needsSpace(between: classify(last), and: right.map(classify))
        )
    }

    public static func deliverable(_ raw: String,
                                   before left: Character? = nil,
                                   after right: Character? = nil) -> String {
        let normalized = normalize(raw)
        let spacing = spacing(inserting: normalized, before: left, after: right)
        return (spacing.leadingSpace ? " " : "")
            + normalized
            + (spacing.trailingSpace ? " " : "")
    }

    private enum BoundaryClass {
        case blank
        case open
        case pathJoiner
        case close
        case word
    }

    private static func isDeliverable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" { return true }
        if scalar == "\u{FEFF}" { return false }
        return scalar.properties.generalCategory != .control
    }

    private static func classify(_ character: Character) -> BoundaryClass {
        if character.isWhitespace { return .blank }
        switch character {
        case "(", "[", "{", "<":
            return .open
        case "/":
            return .pathJoiner
        default:
            return character.isPunctuation ? .close : .word
        }
    }

    private static func needsSpace(between left: BoundaryClass?,
                                   and right: BoundaryClass?) -> Bool {
        guard let left, let right else { return false }
        if left == .blank || right == .blank { return false }
        if left == .open || left == .pathJoiner { return false }
        if right == .close || right == .pathJoiner { return false }
        return true
    }
}
