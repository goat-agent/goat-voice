import AppKit
import Foundation

struct AudioLevelHistory: Equatable, Sendable {
    let capacity: Int
    private(set) var samples: [Double] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func push(_ level: Double) {
        samples.append(level.isFinite ? min(max(level, 0), 1) : 0)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    var bars: [Double] {
        guard samples.count < capacity else { return samples }
        return Array(repeating: 0, count: capacity - samples.count) + samples
    }
}

final class WaveformHistoryView: NSView {
    static func visibleLevel(forRMS rms: Double) -> Double {
        guard rms.isFinite, rms > 0 else { return 0 }
        return min(max((20 * log10(rms) + 54) / 48, 0), 1)
    }

    var dimmed = false {
        didSet { needsDisplay = true }
    }

    private(set) var history = AudioLevelHistory(capacity: CapsuleMetrics.waveformBarCapacity)

    override var intrinsicContentSize: NSSize { CapsuleMetrics.waveformSize }

    func push(_ level: Double) {
        history.push(level)
        needsDisplay = true
    }

    func reset() {
        history.reset()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bars = history.bars
        guard !bars.isEmpty else { return }
        let barWidth: CGFloat = 3
        let gap: CGFloat = 2
        let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
        var x = max(0, (bounds.width - totalWidth) / 2)
        for level in bars {
            let visible = Self.visibleLevel(forRMS: level)
            let height = max(2, bounds.height * CGFloat(visible))
            let rect = CGRect(
                x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
            let color = NSColor.secondaryLabelColor
            (dimmed ? color.withAlphaComponent(0.35) : color).setFill()
            NSBezierPath(
                roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2
            ).fill()
            x += barWidth + gap
        }
    }
}

final class IndicatorView: NSView {
    var reduceMotion = false {
        didSet {
            guard reduceMotion else { return }
            capsule.layer?.removeAllAnimations()
        }
    }
    var onHUDAction: (() -> Void)? {
        get { hudView.onAction }
        set { hudView.onAction = newValue }
    }

    private let capsule = NSVisualEffectView()
    private let waveformView = WaveformHistoryView()
    private let statusLabel = NSTextField(labelWithString: "Listening")
    private let previewCaption = NSTextField(labelWithString: "Preview · may change")
    private let previewLabel = NSTextView(frame: .zero)
    private let hudView = HUDView()

    private var phase: StripPhase?
    private var preview: String?
    private var notice: Notice?
    private var transitionGeneration: UInt64 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        capsule.material = .hudWindow
        capsule.blendingMode = .withinWindow
        capsule.state = .active
        capsule.wantsLayer = true
        capsule.layer?.masksToBounds = true

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .labelColor
        previewCaption.font = .systemFont(ofSize: 10, weight: .medium)
        previewCaption.textColor = .secondaryLabelColor

        previewLabel.font = CapsuleMetrics.previewFont
        previewLabel.textColor = .labelColor
        previewLabel.isEditable = false
        previewLabel.isSelectable = false
        previewLabel.drawsBackground = false
        previewLabel.textContainerInset = .zero
        previewLabel.textContainer?.lineFragmentPadding = 0
        previewLabel.textContainer?.widthTracksTextView = true


        capsule.addSubview(waveformView)
        capsule.addSubview(statusLabel)
        capsule.addSubview(previewCaption)
        capsule.addSubview(previewLabel)
        capsule.isHidden = true
        addSubview(capsule)

        hudView.isHidden = true
        addSubview(hudView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        if notice != nil {
            let size = hudView.intrinsicContentSize
            hudView.frame = CGRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            return
        }
        capsule.frame = bounds
        capsule.layer?.cornerRadius = CapsuleMetrics.cornerRadius(forHeight: bounds.height)

        let waveSize = CapsuleMetrics.waveformSize
        let x = CapsuleMetrics.horizontalPadding
        let headerY = bounds.height - CapsuleMetrics.baseHeight / 2
        let statusX = x
        statusLabel.frame = CGRect(
            x: statusX, y: headerY - 8,
            width: max(0, bounds.width - statusX - waveSize.width - 24), height: 16)
        waveformView.frame = CGRect(
            x: bounds.width - x - waveSize.width, y: headerY - waveSize.height / 2,
            width: waveSize.width, height: waveSize.height)
        previewCaption.isHidden = preview == nil
        previewLabel.isHidden = preview == nil
        if preview != nil {
            let textWidth = max(0, bounds.width - x * 2)
            previewCaption.frame = CGRect(
                x: x, y: bounds.height - CapsuleMetrics.baseHeight - 11,
                width: textWidth, height: 12)
            previewLabel.frame = CGRect(
                x: x, y: 10, width: textWidth,
                height: max(0, bounds.height - CapsuleMetrics.baseHeight - 28))
        }
    }

    func fittingSize(maxWidth: CGFloat) -> CGSize {
        let cap = min(maxWidth, CapsuleMetrics.maxWidth)
        if notice != nil {
            let size = hudView.intrinsicContentSize
            return CGSize(width: min(size.width, cap), height: size.height)
        }
        guard let preview else {
            return CGSize(width: min(CapsuleMetrics.minWidth, cap), height: CapsuleMetrics.baseHeight)
        }
        let textWidth = max(1, cap - CapsuleMetrics.horizontalPadding * 2 - 4)
        let visibleText = Self.visiblePreview(preview, width: textWidth)
        previewLabel.string = visibleText
        let textHeight = PreviewTextLayout.height(of: visibleText, width: textWidth)
        return CGSize(width: cap, height: CapsuleMetrics.baseHeight + 28 + textHeight)
    }

    static func visiblePreview(_ text: String, width: CGFloat) -> String {
        PreviewTextLayout.visibleSuffix(of: text, width: width)
    }

    func showListening(animated: Bool) {
        guard phase != .listening || capsule.isHidden else { return }
        transitionGeneration &+= 1
        notice = nil
        hudView.isHidden = true
        phase = .listening
        statusLabel.stringValue = "Listening"
        setPreview(nil)
        waveformView.reset()
        waveformView.dimmed = false
        capsule.isHidden = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Listening")
        applyAccessibilityValue()
        needsLayout = true
        capsule.alphaValue = 1
    }

    func setAudioLevel(_ level: Double) {
        guard phase == .listening, !capsule.isHidden else { return }
        waveformView.push(level)
    }

    func setPreview(_ text: String?) {
        let flattened = text?
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        let normalized = (flattened?.trimmingCharacters(in: .whitespaces).isEmpty == false)
            ? flattened : nil
        guard normalized != preview else { return }
        preview = normalized
        previewLabel.string = normalized ?? ""
        applyAccessibilityValue()
        needsLayout = true
    }

    func beginProcessing() {
        guard phase != .processing else { return }
        notice = nil
        hudView.isHidden = true
        phase = .processing
        transitionGeneration &+= 1
        statusLabel.stringValue = "Transcribing"
        capsule.isHidden = false
        waveformView.dimmed = true
        setAccessibilityLabel("Transcribing")
        applyAccessibilityValue()
        needsLayout = true
    }

    func showNotice(_ newNotice: Notice) {
        transitionGeneration &+= 1
        setPreview(nil)
        notice = newNotice
        phase = nil
        capsule.isHidden = true
        capsule.alphaValue = 1
        hudView.configure(with: newNotice)
        hudView.isHidden = false
        setAccessibilityElement(false)
        needsLayout = true
        if let app = NSApp {
            NSAccessibility.post(
                element: app,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: newNotice.text,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }

    func exit(kind: ExitKind, completion: @escaping () -> Void) {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        setPreview(nil)
        phase = nil
        let duration: CFTimeInterval = kind == .delivered ? 0.08 : 0.06
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? min(duration, 0.05) : duration
            capsule.animator().alphaValue = 0
            hudView.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) {
            guard self.transitionGeneration == generation else { return }
            self.capsule.isHidden = true
            self.capsule.alphaValue = 1
            self.hudView.isHidden = true
            self.hudView.alphaValue = 1
            self.notice = nil
            completion()
        }
    }

    func hideImmediately() {
        transitionGeneration &+= 1
        setPreview(nil)
        phase = nil
        notice = nil
        capsule.layer?.removeAllAnimations()
        capsule.isHidden = true
        capsule.alphaValue = 1
        hudView.isHidden = true
        hudView.alphaValue = 1
    }

    private func applyAccessibilityValue() {
        setAccessibilityValue(preview)
    }

}
