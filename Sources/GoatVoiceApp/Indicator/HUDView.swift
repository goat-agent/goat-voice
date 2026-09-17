import AppKit
import Foundation

final class HUDView: NSView {
    static let widthRange: ClosedRange<CGFloat> = 160...380
    static let heightRange: ClosedRange<CGFloat> = 32...38

    var onAction: (() -> Void)?

    private let effectView = NSVisualEffectView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        effectView.material = .hudWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 17
        effectView.layer?.masksToBounds = true
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        messageLabel.textColor = .labelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = 1
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.font = .systemFont(ofSize: 12, weight: .medium)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.target = self
        actionButton.action = #selector(actionPressed)

        let content = NSStackView(views: [messageLabel, actionButton])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 10
        content.detachesHiddenViews = true
        content.translatesAutoresizingMaskIntoConstraints = false

        addSubview(effectView)
        effectView.addSubview(content)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -14),
            content.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(with notice: Notice) {
        messageLabel.stringValue = notice.text
        messageLabel.setAccessibilityLabel(notice.text)
        if let actionTitle = notice.actionTitle {
            actionButton.title = actionTitle
            actionButton.setAccessibilityLabel(actionTitle)
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let labelWidth = messageLabel.intrinsicContentSize.width
        let buttonWidth = actionButton.isHidden ? 0 : actionButton.intrinsicContentSize.width + 10
        let width = (28 + labelWidth + buttonWidth).clamped(to: Self.widthRange)
        return NSSize(width: width, height: CGFloat(34).clamped(to: Self.heightRange))
    }

    @objc private func actionPressed() {
        onAction?()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
