import AppKit

@MainActor
enum PreviewTextLayout {
    static func height(of text: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [.font: CapsuleMetrics.previewFont])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return max(ceil(manager.usedRect(for: container).height), CapsuleMetrics.previewLineHeight)
    }

    static func visibleSuffix(of text: String, width: CGFloat) -> String {
        let maximumHeight = CGFloat(CapsuleMetrics.maxPreviewLines) * CapsuleMetrics.previewLineHeight
        func fits(_ candidate: String) -> Bool {
            height(of: candidate, width: width) <= maximumHeight
        }
        guard !fits(text) else { return text }
        let characters = Array(text)
        var lower = 0
        var upper = characters.count
        while lower < upper {
            let count = (lower + upper + 1) / 2
            if fits("…" + String(characters.suffix(count))) {
                lower = count
            } else {
                upper = count - 1
            }
        }
        return "…" + String(characters.suffix(lower))
    }
}
