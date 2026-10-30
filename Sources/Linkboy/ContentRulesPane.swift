import AppKit

/// Settings ▸ Content Blocking: a plain-text editor for the WebKit content-rule-list JSON. Save compiles it; a
/// compile error shows here and the previous rules stay active.
final class ContentRulesPane: NSView {
    private let text = NSTextView()
    private let save = NSButton(title: "Save", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.allowsUndo = true
        text.string = ContentRules.shared.savedSource()
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 480).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true

        save.bezelStyle = .rounded
        save.target = self
        save.action = #selector(saveRules)
        status.lineBreakMode = .byWordWrapping
        status.preferredMaxLayoutWidth = 400
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [save, status])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8

        let stack = NSStackView(views: [NSTextField(labelWithString: "Content rules (WebKit content blocker JSON)"), scroll, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        pinTopLeading(stack, in: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows why the saved rules aren't active, or nothing when they are.
    func refreshStatus() { setStatus(ContentRules.shared.error ?? "", failed: ContentRules.shared.error != nil) }

    @objc private func saveRules() {
        save.isEnabled = false
        let source = text.string
        Task { @MainActor [weak self] in
            let failure = await ContentRules.shared.save(source)
            guard let self else { return }
            self.save.isEnabled = true
            self.setStatus(failure ?? "Saved", failed: failure != nil)
        }
    }

    private func setStatus(_ text: String, failed: Bool) {
        status.stringValue = text
        status.textColor = failed ? .systemRed : .secondaryLabelColor
    }
}
