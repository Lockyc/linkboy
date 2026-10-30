import AppKit

/// What the toolbar shows. Each control is always present; a nil reason enables it, a reason disables it
/// and becomes its tooltip.
struct ToolbarState {
    var previous: String?
    var next: String?
    /// The page segment of the Page/Comments switch, and the switch as a whole.
    var pane: String?
    var comments: String?
    var showingComments = false
    var star: String?
    var starred = false
    var openInBrowser: String?
    var markAll: String?
    var undoMarkAll: String?
}

/// The fixed row above the list and viewer: Previous · Next · Page/Comments · Star · Open in Browser · Mark All… ·
/// Undo Mark All. Controls keep their size and position in every state.
final class ToolbarView: NSView {
    enum Action { case previous, next, page, comments, star, openInBrowser, markAll, undoMarkAll }
    var onAction: ((Action) -> Void)?

    private let previous = ToolbarView.button("Previous", symbol: "chevron.up")
    private let next = ToolbarView.button("Next", symbol: "chevron.down")
    private let pane = NSSegmentedControl(labels: ["Page", "Comments"], trackingMode: .selectOne, target: nil, action: nil)
    private let star = ToolbarView.button("Star", symbol: "star")
    private let open = ToolbarView.button("Open in Browser", symbol: "safari")
    private let markAll = ToolbarView.button("Mark All…", symbol: "checkmark.circle")
    private let undoMarkAll = ToolbarView.button("Undo Mark All", symbol: "arrow.uturn.backward")

    override init(frame: NSRect) {
        super.init(frame: frame)
        pane.selectedSegment = 0
        pane.segmentStyle = .rounded
        for (control, action) in [(previous, Action.previous), (next, .next), (star, .star), (open, .openInBrowser),
                                  (markAll, .markAll), (undoMarkAll, .undoMarkAll)] {
            control.target = self
            control.action = #selector(clicked(_:))
            control.tag = tags.firstIndex(of: action)!
        }
        pane.target = self
        pane.action = #selector(paneChanged)
        star.widthAnchor.constraint(equalToConstant: 92).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [previous, next, pane, star, open, spacer, markAll, undoMarkAll])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(_ s: ToolbarState) {
        Self.set(previous, s.previous)
        Self.set(next, s.next)
        Self.set(open, s.openInBrowser)
        Self.set(markAll, s.markAll)
        Self.set(undoMarkAll, s.undoMarkAll)
        Self.set(star, s.star)
        star.title = s.starred ? "Starred" : "Star"
        star.image = NSImage(systemSymbolName: s.starred ? "star.fill" : "star", accessibilityDescription: nil)

        pane.isEnabled = s.pane == nil
        pane.toolTip = s.pane
        pane.setEnabled(s.comments == nil, forSegment: 1)
        pane.setToolTip(s.comments, forSegment: 1)
        pane.selectedSegment = s.showingComments ? 1 : 0
    }

    private let tags: [Action] = [.previous, .next, .star, .openInBrowser, .markAll, .undoMarkAll]

    @objc private func clicked(_ sender: NSButton) { onAction?(tags[sender.tag]) }

    @objc private func paneChanged() { onAction?(pane.selectedSegment == 1 ? .comments : .page) }

    private static func set(_ b: NSButton, _ reason: String?) {
        b.isEnabled = reason == nil
        b.toolTip = reason
    }

    private static func button(_ title: String, symbol: String) -> NSButton {
        let b = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                         target: nil, action: nil)
        b.imagePosition = .imageLeading
        b.bezelStyle = .rounded
        return b
    }
}
