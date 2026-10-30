import AppKit
import LinkboyCore

/// The snapshot's entries, one cell-reused row each: title, then feed title and relative time. Read rows dim.
final class EntryListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// Called when the user picks a row (click or arrow keys).
    var onSelect: ((Int) -> Void)?

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private var ids: [Int64] = []
    private var entries: [Int64: Entry] = [:]
    private var fontSize: CGFloat = 13
    private var density: Density = .regular
    private var selectingProgrammatically = false
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .plain
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
        applyRowHeight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Replaces the rows; `entries` supplies what to show for each id, `emptyText` shows when there are none.
    func setRows(ids: [Int64], entries: [Entry], emptyText: String) {
        self.ids = ids
        self.entries = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        empty.stringValue = emptyText
        empty.isHidden = !ids.isEmpty
        table.reloadData()
    }

    /// Redraws the rows showing these entries in place: no reload of the list, no reordering.
    func update(_ changed: [Entry]) {
        var rows = IndexSet()
        for e in changed {
            entries[e.id] = e
            if let row = ids.firstIndex(of: e.id) { rows.insert(row) }
        }
        table.reloadData(forRowIndexes: rows, columnIndexes: [0])
    }

    func select(row: Int?) {
        selectingProgrammatically = true
        defer { selectingProgrammatically = false }
        guard let row, ids.indices.contains(row) else { return table.deselectAll(nil) }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func apply(fontSize: Double, density: Density) {
        self.fontSize = CGFloat(fontSize)
        self.density = density
        applyRowHeight()
        table.reloadData()
    }

    private func applyRowHeight() {
        let lines = NSFont.systemFont(ofSize: fontSize).boundingRectForFont.height
            + NSFont.systemFont(ofSize: max(fontSize - 2, 9)).boundingRectForFont.height
        table.rowHeight = ceil(lines * 0.85) + (density == .compact ? 4 : 12)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: EntryCell.id, owner: nil) as? EntryCell ?? EntryCell()
        cell.configure(entries[ids[row]], fontSize: fontSize, density: density, relative: Self.relative)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selectingProgrammatically, table.selectedRow >= 0 else { return }
        onSelect?(table.selectedRow)
    }
}

private final class EntryCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("EntryCell")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var topInset: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        for f in [title, detail] {
            f.lineBreakMode = .byTruncatingTail
            f.translatesAutoresizingMaskIntoConstraints = false
            f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(f)
        }
        topInset = title.topAnchor.constraint(equalTo: topAnchor, constant: 6)
        NSLayoutConstraint.activate([
            topInset,
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ entry: Entry?, fontSize: CGFloat, density: Density, relative: RelativeDateTimeFormatter) {
        topInset.constant = density == .compact ? 2 : 6
        title.font = .systemFont(ofSize: fontSize, weight: .medium)
        detail.font = .systemFont(ofSize: max(fontSize - 2, 9))
        guard let entry else {
            title.stringValue = ""
            detail.stringValue = ""
            return
        }
        title.stringValue = entry.title
        detail.stringValue = "\(entry.feed.title) · \(relative.localizedString(for: entry.publishedAt, relativeTo: Date()))"
        let read = entry.status != .unread
        title.textColor = read ? .tertiaryLabelColor : .labelColor
        detail.textColor = read ? .tertiaryLabelColor : .secondaryLabelColor
    }
}
