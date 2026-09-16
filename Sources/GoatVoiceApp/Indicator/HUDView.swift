import AppKit
import Foundation

final class HUDView: NSView {
    static let widthRange: ClosedRange<CGFloat> = 220...300
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

        addSubview(effectView)
        effectView.addSubview(messageLabel)
        effectView.addSubview(actionButton)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            messageLabel.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 14),
            messageLabel.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),

            actionButton.leadingAnchor.constraint(
                equalTo: messageLabel.trailingAnchor, constant: 10),
            actionButton.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -10),
            actionButton.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
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
        let width = (14 + labelWidth + buttonWidth + 10).clamped(to: Self.widthRange)
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
