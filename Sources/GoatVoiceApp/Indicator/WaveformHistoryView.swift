import AppKit

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
        Array(repeating: 0, count: max(0, capacity - samples.count)) + samples
    }
}

final class WaveformHistoryView: NSView {
    static func visibleLevel(forRMS rms: Double) -> Double {
        guard rms.isFinite, rms > 0 else { return 0 }
        return min(max((20 * log10(rms) + 54) / 48, 0), 1)
    }

    var reduceMotion = false {
        didSet {
            if reduceMotion { bars.forEach { $0.removeAllAnimations() } }
        }
    }

    var dimmed = false {
        didSet { updateBars(animated: false) }
    }

    private(set) var history = AudioLevelHistory(capacity: CapsuleMetrics.waveformBarCapacity)
    private let bars = (0..<CapsuleMetrics.waveformBarCapacity).map { _ in CALayer() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for bar in bars { layer?.addSublayer(bar) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize { CapsuleMetrics.waveformSize }

    override func layout() {
        super.layout()
        updateBars(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBars(animated: false)
    }

    func push(_ level: Double) {
        history.push(level)
        updateBars(animated: !reduceMotion)
    }

    func reset() {
        history.reset()
        bars.forEach { $0.removeAllAnimations() }
        updateBars(animated: false)
    }

    private func updateBars(animated: Bool) {
        let samples = history.bars
        let gap: CGFloat = 2
        let width = max(1, (bounds.width - CGFloat(bars.count - 1) * gap) / CGFloat(bars.count))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, bar) in bars.enumerated() {
                let level = CGFloat(Self.visibleLevel(forRMS: samples[index]))
                let height = 2 + level * max(0, bounds.height - 2)
                let recency = CGFloat(index + 1) / CGFloat(bars.count)
                let color = dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor.blended(
                    withFraction: level * 0.8, of: .controlAccentColor) ?? .labelColor
                CATransaction.begin()
                CATransaction.setDisableActions(!animated)
                CATransaction.setAnimationDuration(height > bar.bounds.height ? 0.08 : 0.18)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
                bar.frame = CGRect(x: CGFloat(index) * (width + gap),
                                   y: (bounds.height - height) / 2, width: width, height: height)
                bar.cornerRadius = width / 2
                bar.backgroundColor = color.cgColor
                bar.opacity = dimmed ? 0.3 : Float(0.22 + recency * 0.23 + level * 0.55)
                CATransaction.commit()
            }
        }
    }
}
