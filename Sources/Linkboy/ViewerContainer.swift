import AppKit
import LinkboyCore

enum ViewerPane {
    case page, comments
}

/// The reading area: a page viewer and a comments viewer per item, shown one at a time (single layout) or
/// side by side. Switching pane or layout only shows and hides them, keeping each one's scroll and history;
/// moving to another item gives both fresh web views, or the ones `prefetcher` already loaded for it.
final class ViewerContainer: NSView, NSSplitViewDelegate {
    static let noComments = "This item has no comments link"
    static let noItem = "No item selected"

    /// Called with the page's share of the side-by-side split when the user drags its divider.
    var onSplitFractionChange: ((Double) -> Void)?
    /// A bound key pressed in either viewer's page outside a text control.
    var onPageKey: ((KeyCombo) -> Void)? {
        didSet { [pageViewer, commentsViewer].forEach { $0.onPageKey = onPageKey } }
    }
    var splitFraction: Double = 0.5

    /// Replaced (never mutated in place) when a prefetched pair is adopted.
    private(set) var pageViewer = WebViewer()
    private(set) var commentsViewer = WebViewer()
    /// Loads the next item offscreen; `show(…, usePrefetched: true)` adopts what it holds for that item.
    let prefetcher = Prefetcher()
    private let split = NSSplitView()
    private let commentsSlot = NSView()
    /// Covers the whole viewer: no item, or (single layout) an item with no comments link.
    private let cover = Cover()
    /// Covers the comments pane in side-by-side layout when the item has no comments link.
    private let commentsCover = Cover()
    private var layoutMode: Layout?
    private var shownPane: ViewerPane = .page
    private var settingSplit = false
    /// The item the viewers belong to, and which of them has loaded it.
    private var entryID: Int64?
    private var pageLoaded = false
    private var commentsLoaded = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        pin(commentsViewer, in: commentsSlot)
        pin(commentsCover, in: commentsSlot)
        commentsCover.text = Self.noComments
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `usePrefetched` applies only when this moves to a different item (moving forward): the item's prefetched
    /// viewers, if any, replace fresh ones.
    func show(entry: Entry, layout: Layout, pane: ViewerPane, usePrefetched: Bool = false) {
        var restoreFocus = false
        if entry.id != entryID {
            if usePrefetched, let taken = prefetcher.take(for: entry) {
                restoreFocus = pageViewer.containsFirstResponder || commentsViewer.containsFirstResponder
                adopt(taken)
            } else {
                reset()
            }
            entryID = entry.id
        }
        arrange(layout)
        shownPane = pane
        switch layout {
        case .single:
            let showComments = pane == .comments
            if showComments, entry.commentsURL == nil { coverAll(Self.noComments) } else { cover.isHidden = true }
            if showComments { loadComments(entry) } else { loadPage(entry) }
            let (shown, hidden) = showComments ? (commentsViewer, pageViewer) : (pageViewer, commentsViewer)
            let movesFocus = hidden.containsFirstResponder
            pageViewer.isHidden = showComments
            commentsSlot.isHidden = !showComments
            if movesFocus { shown.takeFocus() }
        case .sideBySide:
            cover.isHidden = true
            pageViewer.isHidden = false
            commentsSlot.isHidden = false
            loadPage(entry)
            loadComments(entry)
        }
        commentsCover.isHidden = entry.commentsURL != nil || layout == .single
        if restoreFocus { focusedViewer.takeFocus() }
    }

    /// The empty viewer, in whichever layout is current.
    func showEmpty(layout: Layout) {
        prefetcher.discardAll()
        reset()
        entryID = nil
        arrange(layout)
        coverAll(Self.noItem)
    }

    /// The pane the keyboard acts on: in single layout the one showing; side by side, the one holding keyboard
    /// focus, else the page.
    var focusedViewer: WebViewer {
        switch layoutMode {
        case .sideBySide: commentsViewer.containsFirstResponder ? commentsViewer : pageViewer
        default: shownPane == .comments ? commentsViewer : pageViewer
        }
    }

    /// A page (not just a viewer awaiting its page) holds keyboard focus.
    var pageHasKeyboard: Bool { pageViewer.pageHasKeyboard || commentsViewer.pageHasKeyboard }

    /// The visible viewer under a point in window coordinates, if any.
    func viewer(atWindowPoint point: NSPoint) -> WebViewer? {
        [pageViewer, commentsViewer].first { v in
            !v.isHiddenOrHasHiddenAncestor && v.bounds.contains(v.convert(point, from: nil))
        }
    }

    /// Moves the side-by-side divider to `splitFraction` (after a settings change). Resizes of the split keep the
    /// fraction through `splitView(_:resizeSubviewsWithOldSize:)`.
    func applySplitFraction() {
        guard layoutMode == .sideBySide, split.bounds.width > 0 else { return }
        settingSplit = true
        split.setPosition(split.bounds.width * splitFraction, ofDividerAt: 0)
        settingSplit = false
    }

    // MARK: - Loading

    private func reset() {
        pageViewer.resetHistory()
        commentsViewer.resetHistory()
        pageLoaded = false
        commentsLoaded = false
    }

    /// Swaps in prefetched viewers as this item's: already loading, so they count as loaded and their history
    /// starts at that load. A side the item doesn't have prefetched is reset as usual.
    private func adopt(_ taken: Prefetcher.Viewers) {
        if let page = taken.page {
            pageViewer.discard()
            pageViewer.removeFromSuperview()
            pageViewer = page
            page.onPageKey = onPageKey
            pageLoaded = true
            layoutMode = nil // the page viewer's host changed; `arrange` rebuilds
        } else {
            pageViewer.resetHistory()
            pageLoaded = false
        }
        if let comments = taken.comments {
            commentsViewer.discard()
            commentsViewer.removeFromSuperview()
            commentsViewer = comments
            comments.onPageKey = onPageKey
            commentsSlot.addSubview(comments, positioned: .below, relativeTo: commentsCover)
            constrain(comments, to: commentsSlot)
            commentsLoaded = true
        } else {
            commentsViewer.resetHistory()
            commentsLoaded = false
        }
    }

    private func loadPage(_ entry: Entry) {
        guard !pageLoaded else { return }
        pageLoaded = true
        pageViewer.load(entry.url)
    }

    private func loadComments(_ entry: Entry) {
        guard !commentsLoaded, let url = entry.commentsURL else { return }
        commentsLoaded = true
        commentsViewer.load(url)
    }

    // MARK: - Arrangement

    private func arrange(_ layout: Layout) {
        guard layout != layoutMode else { return }
        layoutMode = layout
        subviews.forEach { $0.removeFromSuperview() }
        split.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch layout {
        case .single:
            pin(pageViewer, in: self)
            pin(commentsSlot, in: self)
        case .sideBySide:
            // The split's delegate sets pane frames; single layout's pin left these views constraint-driven.
            pageViewer.translatesAutoresizingMaskIntoConstraints = true
            commentsSlot.translatesAutoresizingMaskIntoConstraints = true
            split.addArrangedSubview(pageViewer)
            split.addArrangedSubview(commentsSlot)
            pin(split, in: self)
        }
        pin(cover, in: self)
    }

    private func coverAll(_ text: String) {
        cover.text = text
        cover.isHidden = false
    }

    private func pin(_ child: NSView, in host: NSView) {
        host.addSubview(child)
        constrain(child, to: host)
    }

    private func constrain(_ child: NSView, to host: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            child.topAnchor.constraint(equalTo: host.topAnchor),
            child.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    // MARK: - NSSplitViewDelegate

    /// Window resizes and the first layout keep the page's share at `splitFraction`.
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let size = splitView.bounds.size
        let divider = splitView.dividerThickness
        let page = ((size.width - divider) * splitFraction).rounded()
        pageViewer.frame = NSRect(x: 0, y: 0, width: page, height: size.height)
        commentsSlot.frame = NSRect(x: page + divider, y: 0, width: max(0, size.width - page - divider), height: size.height)
    }

    /// Only a drag of the divider changes the saved fraction.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !settingSplit, NSApp.currentEvent?.type == .leftMouseDragged,
              split.bounds.width > 0, let first = split.arrangedSubviews.first else { return }
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
