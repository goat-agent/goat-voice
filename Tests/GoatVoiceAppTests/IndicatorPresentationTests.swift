import CoreGraphics
import Foundation
import XCTest
@testable import GoatVoiceApp

final class IndicatorGeometryTests: XCTestCase {
    private let notchedScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let notchedVisible = CGRect(x: 0, y: 0, width: 1512, height: 950)

    func testCapsuleAttachesBeneathNotch() {
        let layout = NotchGeometry.capsuleLayout(
            screenFrame: notchedScreen,
            visibleFrame: notchedVisible,
            safeAreaTop: 32,
            contentSize: CGSize(width: 220, height: 30))
        XCTAssertEqual(layout.attachment, .notch)
        XCTAssertEqual(layout.frame.maxY, 982 - 32 + CapsuleMetrics.notchTuck, accuracy: 0.001)
        XCTAssertEqual(layout.frame.midX, 756, accuracy: 0.001)
        XCTAssertEqual(layout.frame.width, 220)
        XCTAssertEqual(layout.frame.height, 30)
    }

    func testFloatingCapsuleBelowMenuBarOnNotchlessDisplay() {
        let layout = NotchGeometry.capsuleLayout(
            screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415),
            safeAreaTop: 0,
            contentSize: CGSize(width: 200, height: 30))
        XCTAssertEqual(layout.attachment, .floating)
        XCTAssertEqual(layout.frame.maxY, 1415 - CapsuleMetrics.floatingTopGap, accuracy: 0.001)
        XCTAssertEqual(layout.frame.midX, 1280, accuracy: 0.001)
    }

    func testCapsuleWidthClampedToMaxContentWidth() {
        let narrowVisible = CGRect(x: 0, y: 0, width: 300, height: 900)
        let layout = NotchGeometry.capsuleLayout(
            screenFrame: CGRect(x: 0, y: 0, width: 300, height: 932),
            visibleFrame: narrowVisible,
            safeAreaTop: 32,
            contentSize: CGSize(width: 500, height: 30))
        XCTAssertEqual(layout.maxContentWidth, 300 - CapsuleMetrics.screenEdgeMargin * 2)
        XCTAssertEqual(layout.frame.width, layout.maxContentWidth)
        XCTAssertGreaterThanOrEqual(layout.frame.minX, narrowVisible.minX + CapsuleMetrics.screenEdgeMargin - 0.001)
        XCTAssertLessThanOrEqual(layout.frame.maxX, narrowVisible.maxX - CapsuleMetrics.screenEdgeMargin + 0.001)
    }

    func testMaxContentWidthCapsAtMetricCeiling() {
        XCTAssertEqual(
            NotchGeometry.maxContentWidth(visibleFrame: CGRect(x: 0, y: 0, width: 5000, height: 900)),
            CapsuleMetrics.maxWidth)
        XCTAssertEqual(
            NotchGeometry.maxContentWidth(visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 900)),
            200 - CapsuleMetrics.screenEdgeMargin * 2)
    }

    func testCapsuleStaysInsideVisibleFrameVertically() {
        let layout = NotchGeometry.capsuleLayout(
            screenFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 575),
            safeAreaTop: 0,
            contentSize: CGSize(width: 300, height: 700))
        XCTAssertGreaterThanOrEqual(
            layout.frame.minY, CapsuleMetrics.screenEdgeMargin - 0.001)
    }
}

final class AudioLevelHistoryTests: XCTestCase {
    func testPushClampsLevelsIntoUnitRange() {
        var history = AudioLevelHistory(capacity: 4)
        history.push(-0.5)
        history.push(0.25)
        history.push(1.4)
        XCTAssertEqual(history.samples, [0, 0.25, 1])
    }

    func testHistoryDropsOldestBeyondCapacity() {
        var history = AudioLevelHistory(capacity: 3)
        for level in [0.1, 0.2, 0.3, 0.4, 0.5] {
            history.push(level)
        }
        XCTAssertEqual(history.samples, [0.3, 0.4, 0.5])
    }

    func testBarsPadLeadingSilenceToCapacity() {
        var history = AudioLevelHistory(capacity: 5)
        history.push(0.5)
        history.push(0.75)
        XCTAssertEqual(history.bars, [0, 0, 0, 0.5, 0.75])
    }

    func testBarsReturnRawSamplesAtFullCapacity() {
        var history = AudioLevelHistory(capacity: 3)
        history.push(0.2)
        history.push(0.4)
        history.push(0.6)
        XCTAssertEqual(history.bars, [0.2, 0.4, 0.6])
    }

    func testResetClearsSamples() {
        var history = AudioLevelHistory(capacity: 3)
        history.push(0.9)
        history.reset()
        XCTAssertTrue(history.samples.isEmpty)
        XCTAssertEqual(history.bars, [0, 0, 0])
    }
}

@MainActor
final class IndicatorPreviewModelTests: XCTestCase {
    private func listening() -> SessionPresentation {
        SessionPresentation(content: .strip(.listening), displayID: nil)
    }

    func testPreviewIgnoredOutsideSession() {
        let model = AppModel()
        model.apply(previewText: "hello")
        XCTAssertNil(model.previewText)
    }

    func testPreviewAcceptedWhileListening() {
        let model = AppModel()
        model.apply(presentation: listening())
        model.apply(previewText: "hello world")
        XCTAssertEqual(model.previewText, "hello world")
    }

    func testPreviewSurvivesTransitionToProcessing() {
        let model = AppModel()
        model.apply(presentation: listening())
        model.apply(previewText: "partial transcript")
        model.apply(presentation: SessionPresentation(content: .strip(.processing), displayID: nil))
        XCTAssertEqual(model.previewText, "partial transcript")
        model.apply(previewText: "updated transcript")
        XCTAssertEqual(model.previewText, "updated transcript")
    }

    func testPreviewClearedOnExit() {
        let model = AppModel()
        model.apply(presentation: listening())
        model.apply(previewText: "text")
        model.apply(presentation: SessionPresentation(content: .exiting(.delivered), displayID: nil))
        XCTAssertNil(model.previewText)
    }

    func testPreviewClearedOnHidden() {
        let model = AppModel()
        model.apply(presentation: listening())
        model.apply(previewText: "text")
        model.apply(presentation: .idle)
        XCTAssertNil(model.previewText)
    }

    func testPreviewClearedOnNotice() {
        let model = AppModel()
        model.apply(presentation: listening())
        model.apply(previewText: "text")
        model.apply(presentation: SessionPresentation(
            content: .notice(Notice(message: .oneMinuteRemaining, action: nil)),
            displayID: nil))
        XCTAssertNil(model.previewText)
    }

    func testPreviewClearedAtNewSessionStart() {
        let model = AppModel()
        model.apply(presentation: listening())
        model.apply(previewText: "old text")
        model.apply(presentation: SessionPresentation(content: .exiting(.cancelled), displayID: nil))
        model.apply(presentation: listening())
        XCTAssertNil(model.previewText)
        model.apply(previewText: "new text")
        XCTAssertEqual(model.previewText, "new text")
    }

    func testPreviewWhitespaceNormalizesToNil() {
        let model = AppModel()
        model.apply(presentation: listening())
        model.apply(previewText: "   \n\t  ")
        XCTAssertNil(model.previewText)
    }

    func testPreviewTrimsSurroundingWhitespace() {
        let model = AppModel()
        model.apply(presentation: listening())
        model.apply(previewText: "  hello  ")
        XCTAssertEqual(model.previewText, "hello")
    }

    func testLatePreviewAfterExitDropped() {
        let model = AppModel()
        model.apply(presentation: listening())
        model.apply(previewText: "text")
        model.apply(presentation: SessionPresentation(content: .exiting(.delivered), displayID: nil))
        model.apply(previewText: "stale")
        XCTAssertNil(model.previewText)
    }

    func testAudioLevelStillResetsOnHidden() {
        let model = AppModel()
        model.apply(presentation: listening())
        model.apply(audioLevel: 0.8)
        model.apply(presentation: .idle)
        XCTAssertEqual(model.audioLevel, 0)
    }
}

@MainActor
final class IndicatorReadabilityTests: XCTestCase {
    func testQuietSpeechIsVisibleWithoutInventingEnergyForSilence() {
        XCTAssertEqual(WaveformHistoryView.visibleLevel(forRMS: 0), 0)
        XCTAssertEqual(WaveformHistoryView.visibleLevel(forRMS: .nan), 0)
        XCTAssertEqual(WaveformHistoryView.visibleLevel(forRMS: .infinity), 0)
        XCTAssertGreaterThan(WaveformHistoryView.visibleLevel(forRMS: 0.02), 0.4)
        XCTAssertGreaterThan(WaveformHistoryView.visibleLevel(forRMS: 0.1),
                             WaveformHistoryView.visibleLevel(forRMS: 0.02))
    }

    func testLongPreviewKeepsNewestWordsWithinVisibleLines() {
        let text = String(repeating: "앞에서 이야기한 내용입니다. ", count: 30) + "마지막으로 할 말입니다."
        let visible = IndicatorView.visiblePreview(text, width: 352)
        XCTAssertTrue(visible.hasPrefix("…"))
        XCTAssertTrue(visible.hasSuffix("마지막으로 할 말입니다."))
        XCTAssertLessThan(visible.count, text.count)
    }

    func testOldExitCannotHideNewListeningSession() async throws {
        let view = IndicatorView(frame: CGRect(x: 0, y: 0, width: 236, height: 38))
        view.reduceMotion = true
        view.showListening(animated: false)
        var oldExitCompleted = false
        view.exit(kind: .delivered) { oldExitCompleted = true }
        view.showListening(animated: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(oldExitCompleted)
    }
}
