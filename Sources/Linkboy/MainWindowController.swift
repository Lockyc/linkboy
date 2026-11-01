import AppKit
import LinkboyCore

/// The reading window: toolbar over a list | viewer split. Reads a frozen `Snapshot` of the chosen scope;
/// sync results only raise the "N new" count until the user retakes the list.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation {
    /// Called once each time Miniflux starts rejecting the key; the app reopens setup and calls `attach` again on
    /// success.
    var onUnauthorized: (() -> Void)?

    private let store: Store
    private let prefs: PreferencesModel
    private var api: MinifluxAPI?
    private var engine: SyncEngine?
    private var events: Task<Void, Never>?
    /// The engine's last sync was rejected for the key; reading carries on locally until `attach`.
    private var rejected = false

    private var snapshot: Snapshot
    private var current: Entry?
    private var pane: ViewerPane = .page
    /// nil until loaded, and when they couldn't be.
    private var categories: [CategoryRef]?
    private var categoriesLoading = false
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
    private var observers: [NSObjectProtocol] = []

    private static let categoriesOffline = "Categories unavailable offline"

    init(store: Store, preferences: PreferencesModel) throws {
        self.store = store
        self.prefs = preferences
        self.snapshot = try Snapshot.take(.unread(category: nil, feed: nil), store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "linkboy"
        window.animationBehavior = .none
        window.minSize = NSSize(width: 860, height: 420)   // wider than the toolbar, so no control is clipped
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
        // Undoing or redoing Mark All can change the open item's read state.
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: undo, queue: .main) { [weak self] _ in
                self?.refreshChrome()
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        monitors.forEach(NSEvent.removeMonitor)
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Starts syncing with `api`, replacing any previous engine once it has fully shut down. `newServer` empties
    /// the local cache in between: another server's entry ids, queued changes and last-sync mark mean nothing
    /// there; if that fails, no engine is attached and the status line says why. Until the new engine is attached,
    /// reading changes stay local.
    func attach(api: MinifluxAPI, newServer: Bool = false) {
        events?.cancel()
        let old = engine
        engine = nil
        rejected = false
        generation += 1
        let generation = generation
        self.api = api
        if newServer {
            categories = nil
            current = nil
            pane = .page
            undo.removeAllActions()
            viewer.showEmpty(layout: prefs.value.layout)
        }
        categoriesLoading = false
        setStatus("Updating…")
        Task { @MainActor [weak self] in
            await old?.shutdown()
            guard let self, self.generation == generation else { return }
            if newServer {
                do {
                    try self.store.reset()
                } catch {
                    // Syncing another server's entries into this cache would mix two servers' ids.
                    self.setStatus("Couldn't clear the local cache: \(error.localizedDescription)")
                    return
                }
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
        WebViewer.pageKeys = p.bindings.pageKeys
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
        prefetchNext()
    }

    /// Points the prefetcher at the item after the open one in the current snapshot; nothing open, nothing held.
    private func prefetchNext() {
        guard let current else { return viewer.prefetcher.discardAll() }
        viewer.prefetcher.prepare(after: current, in: snapshot) { [store] ids in (try? store.entries(ids: ids)) ?? [] }
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

    /// The only route for reading keys, ⌘[ / ⌘] and ⌘R (the Go menu shows them but never acts on them). Keys are caught
    /// before the first responder sees them, but never in another window or while one of the window's own text
    /// fields is being edited. While a page has keyboard focus its unmodified keys go to the page, whose
    /// `FocusProbe` listener sends bound ones back through `routePageKey` when no text control has focus.
    private func installMonitors() {
        viewer.onPageKey = { [weak self] in self?.routePageKey($0) }
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
              let combo = KeyCombo(event: event)
        else { return event }
        if combo == Self.backKey { historyBack(nil); return nil }
        if combo == Self.forwardKey { historyForward(nil); return nil }
        if combo == Self.syncKey { syncNow(nil); return nil }
        guard let action = KeyRouter.route(combo, editableFocused: viewer.pageHasKeyboard, bindings: prefs.value.bindings)
        else { return event }
        perform(action)
        return nil
    }

    static let backKey = KeyCombo(key: "[", modifiers: [.command])
    static let forwardKey = KeyCombo(key: "]", modifiers: [.command])
    static let syncKey = KeyCombo(key: "r", modifiers: [.command])

    /// A key the page has already found bound and outside any text control.
    private func routePageKey(_ combo: KeyCombo) {
        guard window?.isKeyWindow == true,
              let action = KeyRouter.route(combo, editableFocused: false, bindings: prefs.value.bindings) else { return }
        perform(action)
    }

    /// Mouse buttons 4 and 5 (side buttons) go back and forward in the viewer under the pointer, and do nothing
    /// anywhere else. WebKit never hands them to the page, so they're handled here.
    private func routeMouse(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, event.buttonNumber == 3 || event.buttonNumber == 4,
              let target = viewer.viewer(atWindowPoint: event.locationInWindow) else { return event }
        if event.buttonNumber == 3 { target.goBack() } else { target.goForward() }
        return nil
    }

    private func perform(_ action: Action) {
        switch action {
        case .next: goNext(nil)
        case .previous: goPrevious(nil)
        case .togglePane: togglePane()
        case .star: toggleStar()
        case .toggleRead: toggleRead(nil)
        case .openInBrowser: openInBrowser()
        }
    }

    /// Does what clicking the other segment of the Page/Comments control would, and nothing while that is disabled.
    private func togglePane() {
        let s = toolbarState()
        guard s.pane == nil else { return }
        if pane == .page {
            if s.comments == nil { showPane(.comments) }
        } else {
            showPane(.page)
        }
    }

    @objc func historyBack(_ sender: Any?) { viewer.focusedViewer.goBack() }

    @objc func historyForward(_ sender: Any?) { viewer.focusedViewer.goForward() }

    // MARK: - Reading

    private func perform(_ action: ToolbarView.Action) {
        switch action {
        case .previous: goPrevious(nil)
        case .next: goNext(nil)
        case .page: showPane(.page)
        case .comments: showPane(.comments)
        case .star: toggleStar()
        case .toggleRead: toggleRead(nil)
        case .openInBrowser: openInBrowser()
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
        let movesForward = current.flatMap { snapshot.ids.firstIndex(of: $0.id) }.map { $0 < index } ?? true
        snapshot.cursor = index
        if entry.status == .unread {
            entry.status = .read
            record([.status(id: entry.id, .read)])
            list.update([entry])
        }
        current = entry
        pane = .page
        list.select(row: index)
        viewer.show(entry: entry, layout: prefs.value.layout, pane: pane, usePrefetched: movesForward)
        prefetchNext()
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
        record([.starred(id: entry.id, entry.starred)])
        list.update([entry])
        refreshChrome()
    }

    /// Marks the open item unread, or read again; it stays open and in the list either way.
    @objc func toggleRead(_ sender: Any?) {
        guard var entry = current else { return }
        entry.status = entry.status == .unread ? .read : .unread
        current = entry
        record([.status(id: entry.id, entry.status)])
        list.update([entry])
        refreshChrome()
    }

    /// A local read or star: through the engine, which also schedules a sync, or, while none is attached, straight
    /// into the store's queue for the next engine to push.
    private func record(_ changes: [PendingChange]) {
        guard let engine else {
            do { try store.record(changes) } catch { setStatus("Couldn't save to the local cache: \(error.localizedDescription)") }
            return
        }
        Task { @MainActor [weak self] in
            await engine.record(changes)
            self?.refreshChrome()
        }
    }

    private func openInBrowser() {
        guard let current else { return }
        let focused = viewer.focusedViewer
        let start = focused === viewer.commentsViewer ? current.commentsURL ?? current.url : current.url
        NSWorkspace.shared.open(focused.url ?? start)
    }

    // MARK: - Mark all

    @objc func markAll(_ sender: Any?) {
        guard let plan = try? MarkAllPlan.plan(for: snapshot, store: store) else { return }
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
        let ids = plan.ids
        record(ids.map { .status(id: $0, status) })
        let changed = ((try? store.entries(ids: ids)) ?? []).map { e -> Entry in
            var e = e
            e.status = status
            return e
        }
        list.update(changed)
        if let id = current?.id, ids.contains(id) { current?.status = status }
        undo.registerUndo(withTarget: self) { target in
            target.apply(plan, as: status == .read ? .unread : .read)
        }
        undo.setActionName("Mark All")
        refreshChrome()
    }

    // MARK: - Sync

    @objc func syncNow(_ sender: Any?) {
        guard let engine, !rejected else { return }
        setStatus("Updating…")
        Task { await engine.syncNow() }
    }

    /// Why Sync Now is unavailable, or nil when it can run.
    private var syncUnavailable: String? {
        if rejected { return "Miniflux rejected the API key" }
        if engine == nil { return "Not connected to Miniflux" }
        return nil
    }

    private func handle(_ outcome: SyncOutcome) {
        switch outcome {
        case .ok(let newIDs):
            rejected = false
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
            rejected = true
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
            s.isRead = current.status != .unread
        } else {
            s.pane = ViewerContainer.noItem
            s.comments = ViewerContainer.noItem
            s.star = ViewerContainer.noItem
            s.read = ViewerContainer.noItem
            s.isRead = true
            s.openInBrowser = ViewerContainer.noItem
        }
        return s
    }

    /// Why Mark All as Read is unavailable, or nil when it can run.
    private var markAllUnavailable: String? {
        ((try? store.unreadCount(among: snapshot.ids)) ?? 0) == 0 ? "Nothing unread in this list" : nil
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let s = toolbarState()
        switch item.action {
        case #selector(toggleRead(_:)):
            item.title = s.isRead ? "Mark as Unread" : "Mark as Read"
            item.toolTip = s.read
            return s.read == nil
        case #selector(markAll(_:)): item.toolTip = markAllUnavailable; return markAllUnavailable == nil
        case #selector(goNext(_:)): item.toolTip = s.next; return s.next == nil
        case #selector(goPrevious(_:)): item.toolTip = s.previous; return s.previous == nil
        case #selector(historyBack(_:)):
            let ok = viewer.focusedViewer.canGoBack
            item.toolTip = ok ? nil : "No earlier page in this pane"
            return ok
        case #selector(historyForward(_:)):
            let ok = viewer.focusedViewer.canGoForward
            item.toolTip = ok ? nil : "No later page in this pane"
            return ok
        case #selector(syncNow(_:)): item.toolTip = syncUnavailable; return syncUnavailable == nil
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
