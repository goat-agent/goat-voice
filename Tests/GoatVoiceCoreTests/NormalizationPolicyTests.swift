import Foundation
import XCTest
@testable import GoatVoiceCore

final class NormalizationPolicyTests: XCTestCase {
    func testTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(TextNormalization.normalize("  hello\t\n"), "hello")
        XCTAssertEqual(TextNormalization.normalize("\n\n  hello"), "hello")
    }

    func testRemovesTrailingNewlines() {
        XCTAssertEqual(TextNormalization.normalize("line\n"), "line")
        XCTAssertEqual(TextNormalization.normalize("line\n\n\n"), "line")
        XCTAssertEqual(TextNormalization.normalize("line \n \n"), "line")
    }

    func testPreservesInternalNewlines() {
        XCTAssertEqual(TextNormalization.normalize("a\n\nb"), "a\n\nb")
        XCTAssertEqual(TextNormalization.normalize("first\nsecond\n"), "first\nsecond")
    }

    func testUnifiesCarriageReturns() {
        XCTAssertEqual(TextNormalization.normalize("a\r\nb"), "a\nb")
        XCTAssertEqual(TextNormalization.normalize("a\rb"), "a\nb")
        XCTAssertEqual(TextNormalization.normalize("a\r\n"), "a")
    }

    func testStripsControlCharacters() {
        XCTAssertEqual(TextNormalization.normalize("he\u{7}llo"), "hello")
        XCTAssertEqual(TextNormalization.normalize("a\u{0}b\u{7F}c"), "abc")
        XCTAssertEqual(TextNormalization.normalize("a\u{1B}[31mb"), "a[31mb")
        XCTAssertEqual(TextNormalization.normalize("a\u{85}b"), "ab")
    }

    func testPreservesInternalTab() {
        XCTAssertEqual(TextNormalization.normalize("a\tb"), "a\tb")
        XCTAssertEqual(TextNormalization.normalize("\ta"), "a")
    }

    func testStripsByteOrderMark() {
        XCTAssertEqual(TextNormalization.normalize("\u{FEFF}hello"), "hello")
        XCTAssertEqual(TextNormalization.normalize("he\u{FEFF}llo"), "hello")
    }

    func testPreservesKoreanAndEmoji() {
        XCTAssertEqual(
            TextNormalization.normalize("안녕하세요 세계"),
            "안녕하세요 세계"
        )
        XCTAssertEqual(TextNormalization.normalize("done 👍"), "done 👍")
    }

    func testDoesNotCollapseInternalWhitespace() {
        XCTAssertEqual(TextNormalization.normalize("a  b"), "a  b")
    }

    func testAllWhitespaceNormalizesToEmpty() {
        XCTAssertEqual(TextNormalization.normalize(""), "")
        XCTAssertEqual(TextNormalization.normalize(" \n\t\r\n "), "")
    }

    func testBoundaryBetweenWords() {
        XCTAssertEqual(TextNormalization.deliverable("world", before: "o"), " world")
    }

    func testNoSpacingAfterOpenParenthesis() {
        XCTAssertEqual(TextNormalization.deliverable("bar", before: "("), "bar")
        XCTAssertEqual(TextNormalization.deliverable("bar", before: "["), "bar")
        XCTAssertEqual(TextNormalization.deliverable("bar", before: "{"), "bar")
    }

    func testNoSpacingAfterPathSeparator() {
        XCTAssertEqual(TextNormalization.deliverable("local", before: "/"), "local")
    }

    func testNoSpacingBeforePathSeparator() {
        XCTAssertEqual(TextNormalization.deliverable("usr", after: "/"), "usr")
    }

    func testSpacingBeforeOpenParenthesis() {
        XCTAssertEqual(
            TextNormalization.deliverable("(see notes)", before: "o"),
            " (see notes)"
        )
    }

    func testNoSpacingBeforeClosePunctuation() {
        XCTAssertEqual(TextNormalization.deliverable("end", after: ")"), "end")
        XCTAssertEqual(TextNormalization.deliverable("end", after: ","), "end")
        XCTAssertEqual(TextNormalization.deliverable("end", after: "."), "end")
    }

    func testSpacingAfterClosePunctuation() {
        XCTAssertEqual(TextNormalization.deliverable("next", before: "."), " next")
        XCTAssertEqual(TextNormalization.deliverable("next", before: ")"), " next")
    }

    func testSpacingBeforeWord() {
        XCTAssertEqual(TextNormalization.deliverable("start", after: "x"), "start ")
    }

    func testNoSpacingAdjacentToBlank() {
        XCTAssertEqual(TextNormalization.deliverable("bar", before: " "), "bar")
        XCTAssertEqual(TextNormalization.deliverable("bar", before: "\n"), "bar")
        XCTAssertEqual(TextNormalization.deliverable("foo", after: " "), "foo")
        XCTAssertEqual(TextNormalization.deliverable("foo", after: "\n"), "foo")
    }

    func testNoSpacingAtUnknownBoundaries() {
        XCTAssertEqual(TextNormalization.deliverable("hello"), "hello")
        XCTAssertEqual(
            TextNormalization.deliverable("hello", before: nil, after: nil),
            "hello"
        )
    }

    func testKoreanBoundarySpacing() {
        XCTAssertEqual(TextNormalization.deliverable("세계", before: "녕"), " 세계")
    }

    func testDeliverableNormalizesBeforeSpacing() {
        XCTAssertEqual(TextNormalization.deliverable("  world  ", before: "o"), " world")
    }

    func testSpacingReportsBothSides() {
        XCTAssertEqual(
            TextNormalization.spacing(inserting: "mid", before: "a", after: "b"),
            BoundarySpacing(leadingSpace: true, trailingSpace: true)
        )
        XCTAssertEqual(
            TextNormalization.spacing(inserting: "mid", before: "(", after: ")"),
            BoundarySpacing(leadingSpace: false, trailingSpace: false)
        )
    }

    func testSpacingEmptyInsert() {
        XCTAssertEqual(
            TextNormalization.spacing(inserting: "", before: "a", after: "b"),
            .none
        )
    }
}
