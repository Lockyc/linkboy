import AppKit
import LinkboyCore
import WebKit

enum ViewerPane {
    case page, comments
}

/// The reading area: one pane (page or comments) or both side by side. Every web view uses the shared
/// persistent data store, so logins carry across items and launches.
final class ViewerContainer: NSView, NSSplitViewDelegate {
    static let noComments = "This item has no comments link"
    static let noItem = "No item selected"

    /// Called with the page's share of the side-by-side split when the user drags its divider.
    var onSplitFractionChange: ((Double) -> Void)?
    var splitFraction: Double = 0.5

    private let pageView = ViewerContainer.makeWebView()
    private let commentsView = ViewerContainer.makeWebView()
    private let split = NSSplitView()
    private let commentsSlot = NSView()
    /// Covers the whole viewer: no item, or (single layout) an item with no comments link.
    private let cover = Cover()
    /// Covers the comments pane in side-by-side layout when the item has no comments link.
    private let commentsCover = Cover()
    private var layoutMode: Layout?
    private var settingSplit = false
    private var fractionPending = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        pin(commentsView, in: commentsSlot)
        pin(commentsCover, in: commentsSlot)
        commentsCover.text = Self.noComments
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(entry: Entry, layout: Layout, pane: ViewerPane) {
        arrange(layout)
        switch layout {
        case .single:
            if let url = pane == .comments ? entry.commentsURL : entry.url {
                load(pageView, url)
                cover.isHidden = true
            } else {
                coverAll(Self.noComments)
            }
        case .sideBySide:
            cover.isHidden = true
            load(pageView, entry.url)
            if let comments = entry.commentsURL {
                load(commentsView, comments)
                commentsCover.isHidden = true
            } else {
                commentsView.loadHTMLString("", baseURL: nil)
                commentsCover.isHidden = false
            }
        }
    }

    /// The empty viewer, in whichever layout is current.
    func showEmpty(layout: Layout) {
        arrange(layout)
        pageView.loadHTMLString("", baseURL: nil)
        commentsView.loadHTMLString("", baseURL: nil)
        coverAll(Self.noItem)
    }

    /// Puts the side-by-side divider at `splitFraction`; deferred to the next layout while the split has no width.
    func applySplitFraction() {
        guard layoutMode == .sideBySide else { return }
        guard split.bounds.width > 0 else { fractionPending = true; return }
        fractionPending = false
        settingSplit = true
        split.setPosition(split.bounds.width * splitFraction, ofDividerAt: 0)
        settingSplit = false
    }

    override func layout() {
        super.layout()
        if fractionPending { applySplitFraction() }
    }

    // MARK: - Arrangement

    private func arrange(_ layout: Layout) {
        guard layout != layoutMode else { return }
        layoutMode = layout
        subviews.forEach { $0.removeFromSuperview() }
        split.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch layout {
        case .single:
            pin(pageView, in: self)
        case .sideBySide:
            split.addArrangedSubview(pageView)
            split.addArrangedSubview(commentsSlot)
            pin(split, in: self)
            fractionPending = true
            needsLayout = true
        }
        pin(cover, in: self)
    }

    private func coverAll(_ text: String) {
        cover.text = text
        cover.isHidden = false
    }

    private func load(_ view: WKWebView, _ url: URL) {
        if view.url != url { view.load(URLRequest(url: url)) }
    }

    private func pin(_ child: NSView, in host: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            child.topAnchor.constraint(equalTo: host.topAnchor),
            child.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    private static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        return WKWebView(frame: .zero, configuration: config)
    }

    // MARK: - NSSplitViewDelegate

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !settingSplit, split.bounds.width > 0, let first = split.arrangedSubviews.first else { return }
        let fraction = first.frame.width / split.bounds.width
        guard abs(fraction - splitFraction) > 0.001 else { return }
        splitFraction = fraction
        onSplitFractionChange?(fraction)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { 200 }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { splitView.bounds.width - 200 }
}

/// An opaque panel with one centred line of secondary text.
private final class Cover: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
