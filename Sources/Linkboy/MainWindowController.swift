import AppKit
import LinkboyCore

/// The reading window: toolbar over a list | viewer split. Reads a frozen `Snapshot` of the chosen scope;
/// sync results only raise the "N new" count until the user retakes the list.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation {
    /// Called when Miniflux rejects the saved key; the app reopens setup and calls `attach` again on success.
    var onUnauthorized: (() -> Void)?

    private let store: Store
    private let prefs: PreferencesModel
    private var api: MinifluxAPI?
    private var engine: SyncEngine?
    private var events: Task<Void, Never>?

    private var snapshot: Snapshot
    private var current: Entry?
    private var pane: ViewerPane = .page
    /// nil until loaded, and when they couldn't be.
    private var categories: [CategoryRef]?
    private var categoriesLoading = false
    private var ledger = UndoLedger()
    /// Bumped by `attach`, so a categories reply from a previous server is dropped.
    private var generation = 0
    private let undo = UndoManager()

    private let toolbar = ToolbarView()
    private let split = NSSplitView()
    private let listColumn = NSView()
    private let scopePopup = NSPopUpButton()
    private let newButton = NSButton(title: "", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let list = EntryListView()
    private let viewer = ViewerContainer()
    private var settingSplit = false
    private var monitors: [Any] = []

    private static let noItem = "No item selected"
    private static let categoriesOffline = "Categories unavailable offline"

    init(store: Store, preferences: PreferencesModel) throws {
        self.store = store
        self.prefs = preferences
        self.snapshot = try Snapshot.take(.unread(category: nil, feed: nil), store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "linkboy"
        window.animationBehavior = .none
        window.minSize = NSSize(width: 760, height: 420)
        super.init(window: window)
        window.delegate = self
        undo.groupsByEvent = true
        buildContent(in: window)
        window.center()
        window.setFrameAutosaveName("main")

        toolbar.onAction = { [weak self] in self?.perform($0) }
        list.onSelect = { [weak self] in self?.open(index: $0) }
        viewer.onSplitFractionChange = { [weak self] f in self?.prefs.update { $0.splitFraction = f } }
        prefs.observe { [weak self] in self?.apply($0) }

        apply(prefs.value)
        rebuildScopeMenu()
        reloadList()
        viewer.showEmpty(layout: prefs.value.layout)
        setStatus("Updating…")
        refreshChrome()
        installMonitors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { monitors.forEach(NSEvent.removeMonitor) }

    /// Starts syncing with `api`, replacing any previous engine once it has fully shut down. `newServer` empties
    /// the local cache in between: another server's entry ids, queued changes and last-sync mark mean nothing
    /// there. Until the new engine is attached, reading changes stay local.
    func attach(api: MinifluxAPI, newServer: Bool = false) {
        events?.cancel()
        let old = engine
        engine = nil
        generation += 1
        let generation = generation
        self.api = api
        if newServer {
            categories = nil
            current = nil
            pane = .page
            ledger = UndoLedger()
            undo.removeAllActions()
            viewer.showEmpty(layout: prefs.value.layout)
        }
        categoriesLoading = false
        setStatus("Updating…")
        Task { @MainActor [weak self] in
            await old?.shutdown()
            guard let self, self.generation == generation else { return }
            if newServer {
                do { try self.store.reset() } catch { self.setStatus("Couldn't clear the local cache: \(error.localizedDescription)") }
                self.take(.unread(category: nil, feed: nil))
                self.rebuildScopeMenu()
                self.refreshChrome()
            }
            let engine = SyncEngine(api: api, store: self.store)
            self.engine = engine
            self.events = Task { @MainActor [weak self] in
                for await outcome in engine.events { self?.handle(outcome) }
            }
            await engine.start()
        }
        loadCategories()
    }

    // MARK: - Layout

    private func buildContent(in window: NSWindow) {
        scopePopup.autoenablesItems = false
        scopePopup.target = self
        scopePopup.action = #selector(scopeChosen)
        newButton.bezelStyle = .rounded
        newButton.target = self
        newButton.action = #selector(retake)
        newButton.widthAnchor.constraint(equalToConstant: 110).isActive = true
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scopePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let scopeRow = NSStackView(views: [scopePopup, newButton])
        scopeRow.orientation = .horizontal
        scopeRow.spacing = 8
        let header = NSStackView(views: [scopeRow, status])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 6, right: 8)
        scopeRow.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -16).isActive = true
        status.widthAnchor.constraint(equalTo: scopeRow.widthAnchor).isActive = true

        let headerRule = NSBox()
        headerRule.boxType = .separator
        let column = NSStackView(views: [header, headerRule, list])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .leading
        for v in [header, headerRule, list] { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        pin(column, in: listColumn)

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(listColumn)
        split.addArrangedSubview(viewer)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        let toolbarRule = NSBox()
        toolbarRule.boxType = .separator
        let root = NSStackView(views: [toolbar, toolbarRule, split])
        root.orientation = .vertical
        root.spacing = 0
        for v in [toolbar, toolbarRule, split] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        let content = NSView()
        pin(root, in: content)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
    }

    private func apply(_ p: Preferences) {
        list.apply(fontSize: p.listFontSize, density: p.density)
        viewer.splitFraction = p.splitFraction
        if abs(listColumn.frame.width - p.listWidth) > 0.5 {
            settingSplit = true
            split.setPosition(p.listWidth, ofDividerAt: 0)
            settingSplit = false
        }
        if let current { viewer.show(entry: current, layout: p.layout, pane: pane) } else { viewer.showEmpty(layout: p.layout) }
        viewer.applySplitFraction()
        refreshChrome()
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

    // MARK: - Scope

    private func rebuildScopeMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ scope: ListScope?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = scope.map(ScopeBox.init)
            menu.addItem(item)
            return item
        }
        _ = add("Unread", .unread(category: nil, feed: nil))
        _ = add("Starred", .starred)
        menu.addItem(.separator())
        if let categories {
            for c in categories { _ = add(c.title, .unread(category: c.id, feed: nil)) }
        } else {
            let item = add("Categories", nil)
            item.isEnabled = false
            item.toolTip = categoriesLoading ? "Loading categories…" : Self.categoriesOffline
        }
        scopePopup.menu = menu
        let index = menu.items.firstIndex { ($0.representedObject as? ScopeBox)?.scope == snapshot.scope } ?? 0
        scopePopup.selectItem(at: index)
    }

    private func loadCategories() {
        guard let api, categories == nil, !categoriesLoading else { return }
        categoriesLoading = true
        rebuildScopeMenu()
        let generation = generation
        Task { @MainActor [weak self] in
            let result = try? await api.categories()
            guard let self, self.generation == generation else { return }
            self.categoriesLoading = false
            self.categories = result?.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            self.rebuildScopeMenu()
        }
    }

    @objc private func scopeChosen() {
        guard let scope = (scopePopup.selectedItem?.representedObject as? ScopeBox)?.scope else { return }
        guard scope != snapshot.scope else { return }
        current = nil
        pane = .page
        take(scope)
        viewer.showEmpty(layout: prefs.value.layout)
        refreshChrome()
    }

    /// Re-takes the current scope's list, keeping the open item selected if it is still in it.
    @objc private func retake() {
        take(snapshot.scope)
        refreshChrome()
    }

    /// On a cache read failure the previous list stays, with the error in the status line.
    private func take(_ scope: ListScope) {
        do {
            snapshot = try Snapshot.take(scope, store: store)
        } catch {
            setStatus("Couldn't read the local cache: \(error.localizedDescription)")
            rebuildScopeMenu()
            return
        }
        if let id = current?.id, let index = snapshot.ids.firstIndex(of: id) { snapshot.cursor = index }
        reloadList()
    }

    private func reloadList() {
        list.setRows(ids: snapshot.ids, entries: (try? store.entries(ids: snapshot.ids)) ?? [], emptyText: emptyText())
        list.select(row: snapshot.cursor)
    }

    private func emptyText() -> String {
        switch snapshot.scope {
        case .starred: return "No starred items"
        case .unread(let category?, _):
            let title = categories?.first { $0.id == category }?.title
            return title.map { "No unread items in \($0)" } ?? "No unread items"
        case .unread: return "No unread items"
        }
    }

    // MARK: - Keys and mouse

    /// Reading keys are caught before the first responder sees them, so they work while a web page has focus.
    /// They never fire in another window, while one of the window's own text fields is being edited, or (for
    /// unmodified keys) while a text field in the page has focus.
    private func installMonitors() {
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in self?.routeKey(e) ?? e }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { [weak self] e in self?.routeMouse(e) ?? e }) {
            monitors.append(m)
        }
    }

    private func routeKey(_ event: NSEvent) -> NSEvent? {
        guard let window, window.isKeyWindow, event.window === window,
              !(window.firstResponder is NSText || window.firstResponder is NSTextField),
              let combo = KeyCombo(event: event),
              let action = KeyRouter.route(combo, editableFocused: viewer.focusedViewer.editableFocused,
                                           bindings: prefs.value.bindings)
        else { return event }
        perform(action)
        return nil
    }

    /// Mouse buttons 4 and 5 (side buttons) go back and forward in the viewer under the pointer. WebKit never
    /// hands them to the page, so they're handled here.
    private func routeMouse(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, event.buttonNumber == 3 || event.buttonNumber == 4 else { return event }
        let target = viewer.viewer(atWindowPoint: event.locationInWindow) ?? viewer.focusedViewer
        if event.buttonNumber == 3 { target.webView.goBack() } else { target.webView.goForward() }
        return nil
    }

    private func perform(_ action: Action) {
        switch action {
        case .next: goNext(nil)
        case .previous: goPrevious(nil)
        case .togglePane: if prefs.value.layout == .single { showPane(pane == .page ? .comments : .page) }
        case .star: toggleStar()
        case .openInBrowser: openInBrowser()
        }
    }

    @objc func historyBack(_ sender: Any?) { viewer.focusedViewer.webView.goBack() }

    @objc func historyForward(_ sender: Any?) { viewer.focusedViewer.webView.goForward() }

    // MARK: - Reading

    private func perform(_ action: ToolbarView.Action) {
        switch action {
        case .previous: goPrevious(nil)
        case .next: goNext(nil)
        case .page: showPane(.page)
        case .comments: showPane(.comments)
        case .star: toggleStar()
        case .openInBrowser: openInBrowser()
        case .markAll: markAll()
        }
    }

    @objc func goNext(_ sender: Any?) {
        guard snapshot.next() != nil, let cursor = snapshot.cursor else { return }
        open(index: cursor)
    }

    @objc func goPrevious(_ sender: Any?) {
        guard snapshot.previous() != nil, let cursor = snapshot.cursor else { return }
        open(index: cursor)
    }

    private func open(index: Int) {
        guard snapshot.ids.indices.contains(index),
              var entry = (try? store.entries(ids: [snapshot.ids[index]]))?.first else { return }
        snapshot.cursor = index
        if entry.status == .unread {
            entry.status = .read
            let id = entry.id
            if let engine {
                Task { @MainActor [weak self] in
                    await engine.markRead([id])
                    self?.refreshChrome()
                }
            }
            list.update([entry])
        }
        current = entry
        pane = .page
        list.select(row: index)
        viewer.show(entry: entry, layout: prefs.value.layout, pane: pane)
        refreshChrome()
    }

    private func showPane(_ p: ViewerPane) {
        guard let current else { return }
        if p == .comments && current.commentsURL == nil { return refreshChrome() }
        pane = p
        viewer.show(entry: current, layout: prefs.value.layout, pane: p)
        refreshChrome()
    }

    private func toggleStar() {
        guard var entry = current else { return }
        entry.starred.toggle()
        current = entry
        let (id, starred) = (entry.id, entry.starred)
        if let engine { Task { await engine.setStarred(starred, id: id) } }
        list.update([entry])
        refreshChrome()
    }

    private func openInBrowser() {
        guard let current else { return }
        let focused = viewer.focusedViewer
        let start = focused === viewer.commentsViewer ? current.commentsURL ?? current.url : current.url
        NSWorkspace.shared.open(focused.url ?? start)
    }

    // MARK: - Mark all

    private func markAllPlan() -> MarkAllPlan? { try? MarkAllPlan.plan(for: snapshot, store: store) }

    private func markAll() {
        guard let plan = markAllPlan() else { return }
        let alert = NSAlert()
        alert.messageText = plan.prompt
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Mark as Read")
        alert.window.animationBehavior = .none
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        apply(plan, as: .read)
    }

    /// Applies `plan` (or, for `.unread`, takes it back), and registers the opposite with the window's undo.
    private func apply(_ plan: MarkAllPlan, as status: EntryStatus) {
        guard let engine else { return }
        let ids = plan.ids
        if status == .read { ledger.record(plan) }
        Task { @MainActor [weak self] in
            if status == .read { await engine.markRead(ids) } else { await engine.markUnread(ids) }
            self?.refreshChrome()
        }
        let changed = ((try? store.entries(ids: ids)) ?? []).map { e -> Entry in
            var e = e
            e.status = status
            return e
        }
        list.update(changed)
        if let id = current?.id, ids.contains(id) { current?.status = status }
        undo.registerUndo(withTarget: self) { target in
            if status == .read {
                guard let last = target.ledger.undoLast() else { return }
                target.apply(last, as: .unread)
            } else {
                target.apply(plan, as: .read)
            }
        }
        undo.setActionName("Mark All")
        refreshChrome()
    }

    // MARK: - Sync

    private func handle(_ outcome: SyncOutcome) {
        switch outcome {
        case .ok(let newIDs):
            setStatus("Updated \(Date().formatted(date: .omitted, time: .shortened))")
            if snapshot.ids.isEmpty {
                take(snapshot.scope)
            } else if !newIDs.isEmpty {
                let inScope = Set((try? store.entryIDs(matching: snapshot.scope)) ?? [])
                snapshot.noteArrivals(newIDs.filter(inScope.contains))
            }
            loadCategories()
        case .offline:
            setStatus("Offline")
        case .unauthorized:
            setStatus("Miniflux rejected the API key")
            onUnauthorized?()
        case .failed(let message):
            setStatus("Sync failed: \(message)")
        }
        refreshChrome()
    }

    private func setStatus(_ text: String) {
        status.stringValue = text
        status.toolTip = text
    }

    // MARK: - Chrome

    private func refreshChrome() {
        toolbar.update(toolbarState())
        let n = snapshot.newCount
        newButton.title = n > 0 ? "\(n) new" : "No new items"
        newButton.isEnabled = n > 0
        newButton.toolTip = n > 0 ? "Show the \(n) new item\(n == 1 ? "" : "s")" : "Nothing new since this list was loaded"
    }

    private func toolbarState() -> ToolbarState {
        var s = ToolbarState()
        let cursor = snapshot.cursor
        if snapshot.ids.isEmpty {
            s.previous = "The list is empty"
            s.next = "The list is empty"
        } else {
            if cursor == nil || cursor == 0 { s.previous = "No earlier item" }
            if cursor == snapshot.ids.count - 1 { s.next = "This is the last item" }
        }
        if let current {
            if prefs.value.layout == .sideBySide { s.pane = "Page and comments are side by side" }
            if current.commentsURL == nil { s.comments = ViewerContainer.noComments }
            s.showingComments = pane == .comments && prefs.value.layout == .single
            s.starred = current.starred
        } else {
            s.pane = Self.noItem
            s.comments = Self.noItem
            s.star = Self.noItem
            s.openInBrowser = Self.noItem
        }
        if markAllPlan() == nil { s.markAll = "Nothing unread in this list" }
        return s
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let s = toolbarState()
        switch item.action {
        case #selector(goNext(_:)): item.toolTip = s.next; return s.next == nil
        case #selector(goPrevious(_:)): item.toolTip = s.previous; return s.previous == nil
        case #selector(historyBack(_:)): return viewer.focusedViewer.webView.canGoBack
        case #selector(historyForward(_:)): return viewer.focusedViewer.webView.canGoForward
        default: return true
        }
    }

    // MARK: - NSWindowDelegate / NSSplitViewDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { 200 }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { min(600, splitView.bounds.width - 300) }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { view !== listColumn }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !settingSplit, NSApp.currentEvent?.type == .leftMouseDragged else { return }
        let width = listColumn.frame.width.rounded()
        prefs.update { $0.listWidth = width }
    }
}

/// `ListScope` as a menu item's represented object.
private final class ScopeBox: NSObject {
    let scope: ListScope
    init(_ scope: ListScope) { self.scope = scope }
}
