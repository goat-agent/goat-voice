import AppKit
import CoreGraphics
import Foundation

enum IndicatorAttachment: Equatable, Sendable {
    case notch
    case floating
}

struct CapsuleLayout: Equatable, Sendable {
    var attachment: IndicatorAttachment
    var frame: CGRect
    var maxContentWidth: CGFloat
}

enum CapsuleMetrics {
    static let horizontalPadding: CGFloat = 14
    static let waveformSize = CGSize(width: 88, height: 18)
    static let waveformBarCapacity = 18
    static let baseHeight: CGFloat = 34
    static let minWidth: CGFloat = 212
    static let maxWidth: CGFloat = 380
    static let screenEdgeMargin: CGFloat = 12
    static let notchTuck: CGFloat = 2
    static let floatingTopGap: CGFloat = 10
    static let maxPreviewLines = 3
    static let previewLineHeight: CGFloat = 17
    static let previewFont = NSFont.systemFont(ofSize: 13)
    static let cornerRadiusCap: CGFloat = 14

    static func cornerRadius(forHeight height: CGFloat) -> CGFloat {
        min(height / 2, cornerRadiusCap)
    }
}

enum NotchGeometry {
    static func maxContentWidth(visibleFrame: CGRect) -> CGFloat {
        max(0, min(CapsuleMetrics.maxWidth, visibleFrame.width - CapsuleMetrics.screenEdgeMargin * 2))
    }

    static func capsuleLayout(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        contentSize: CGSize
    ) -> CapsuleLayout {
        let attachment: IndicatorAttachment = safeAreaTop > 0 ? .notch : .floating
        let maxWidth = maxContentWidth(visibleFrame: visibleFrame)
        let width = min(contentSize.width, maxWidth)

        let top: CGFloat
        switch attachment {
        case .notch:
            top = screenFrame.maxY - safeAreaTop + CapsuleMetrics.notchTuck
        case .floating:
            top = visibleFrame.maxY - CapsuleMetrics.floatingTopGap
        }

        let availableHeight = max(0, top - visibleFrame.minY - CapsuleMetrics.screenEdgeMargin)
        let height = min(contentSize.height, max(availableHeight, CapsuleMetrics.baseHeight))

        let unclampedX = screenFrame.midX - width / 2
        let minX = visibleFrame.minX + CapsuleMetrics.screenEdgeMargin
        let maxX = max(minX, visibleFrame.maxX - CapsuleMetrics.screenEdgeMargin - width)
        let x = min(max(unclampedX, minX), maxX)

        return CapsuleLayout(
            attachment: attachment,
            frame: CGRect(x: x, y: top - height, width: width, height: height),
            maxContentWidth: maxWidth
        )
    }

    static func capsuleLayout(for screen: NSScreen, contentSize: CGSize) -> CapsuleLayout {
        capsuleLayout(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            contentSize: contentSize
        )
    }

    static func maxContentWidth(for screen: NSScreen) -> CGFloat {
        maxContentWidth(visibleFrame: screen.visibleFrame)
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { self.displayID(of: $0) == displayID }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func isAttached(_ screen: NSScreen) -> Bool {
        guard let id = displayID(of: screen) else { return false }
        return NSScreen.screens.contains { displayID(of: $0) == id }
    }
}
