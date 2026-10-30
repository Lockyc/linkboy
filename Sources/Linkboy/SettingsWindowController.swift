import AppKit
import Carbon.HIToolbox
import LinkboyCore

/// The app's one live copy of `Preferences`: every change is saved and handed to each observer.
final class PreferencesModel {
    private(set) var value = Preferences.load()
    private var observers: [(Preferences) -> Void] = []

    func observe(_ f: @escaping (Preferences) -> Void) { observers.append(f) }

    func update(_ change: (inout Preferences) -> Void) {
        var next = value
        change(&next)
        guard next != value else { return }
        value = next
        value.save()
        observers.forEach { $0(value) }
    }
}

/// Settings in three tabs: General (layout and list), Keys (reading shortcuts) and Content Blocking.
final class SettingsWindowController: NSWindowController {
    private let model: PreferencesModel
    private let layout = NSPopUpButton()
    private let listWidth = NSSlider(value: 320, minValue: 200, maxValue: 600, target: nil, action: nil)
    private let listWidthLabel = NSTextField(labelWithString: "")
    private let fontSize = NSStepper()
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private let density = NSPopUpButton()
    private let keys: KeysPane
    private let rules = ContentRulesPane()

    init(model: PreferencesModel) {
        self.model = model
        keys = KeysPane(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.animationBehavior = .none
        super.init(window: window)

        layout.addItems(withTitles: ["Single pane", "Side by side"])
        density.addItems(withTitles: ["Compact", "Regular"])
        fontSize.minValue = 10
        fontSize.maxValue = 20
        fontSize.increment = 1
        listWidth.isContinuous = true
        for control in [layout, listWidth, fontSize, density] as [NSControl] {
            control.target = self
            control.action = #selector(changed(_:))
        }
        listWidth.widthAnchor.constraint(equalToConstant: 200).isActive = true
        listWidthLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true

        func row(_ views: NSView...) -> NSStackView {
            let s = NSStackView(views: views)
            s.orientation = .horizontal
            s.spacing = 8
            return s
        }
        let general = settingsGrid([
            [NSTextField(labelWithString: "Layout"), layout],
            [NSTextField(labelWithString: "List width"), row(listWidth, listWidthLabel)],
            [NSTextField(labelWithString: "List font size"), row(fontSize, fontSizeLabel)],
            [NSTextField(labelWithString: "List density"), density],
        ])

        let tabs = NSTabView()
        for (title, view) in [("General", general), ("Keys", keys), ("Content Blocking", rules)] as [(String, NSView)] {
            let item = NSTabViewItem()
            item.label = title
            let host = NSView()
            pinTopLeading(view, in: host)
            item.view = host
            tabs.addTabViewItem(item)
        }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        window.contentView = content
        model.observe { [weak self] in self?.show($0) }
        show(model.value)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        rules.refreshStatus()
        window?.center()
        showWindow(nil)
    }

    private func show(_ p: Preferences) {
        layout.selectItem(at: p.layout == .single ? 0 : 1)
        listWidth.doubleValue = p.listWidth
        listWidthLabel.stringValue = "\(Int(p.listWidth.rounded())) pt"
        fontSize.doubleValue = p.listFontSize
        fontSizeLabel.stringValue = "\(Int(p.listFontSize)) pt"
        density.selectItem(at: p.density == .compact ? 0 : 1)
        keys.show(p.bindings)
    }

    @objc private func changed(_ sender: NSControl) {
        model.update { p in
            if sender === layout { p.layout = layout.indexOfSelectedItem == 0 ? .single : .sideBySide }
            if sender === listWidth { p.listWidth = listWidth.doubleValue.rounded() }
            if sender === fontSize { p.listFontSize = fontSize.doubleValue }
            if sender === density { p.density = density.indexOfSelectedItem == 0 ? .compact : .regular }
        }
    }
}

// MARK: - Keys

/// One row per reading action: its shortcut and a button that records a new one. A shortcut already held by
/// another action or a menu item is refused with a message under the rows.
private final class KeysPane: NSView {
    private let model: PreferencesModel
    private var buttons: [Action: NSButton] = [:]
    private let message = NSTextField(labelWithString: "")
    private var recording: Action?
    private var monitor: Any?

    init(model: PreferencesModel) {
        self.model = model
        super.init(frame: .zero)
        var rows: [[NSView]] = []
        for action in Action.allCases {
            let b = NSButton(title: "", target: self, action: #selector(record(_:)))
            b.bezelStyle = .rounded
            b.tag = Action.allCases.firstIndex(of: action)!
            b.widthAnchor.constraint(equalToConstant: 160).isActive = true
            buttons[action] = b
            rows.append([NSTextField(labelWithString: action.title), b])
        }
        for (title, combo) in [("Back", "⌘["), ("Forward", "⌘]")] {
            let b = NSButton(title: combo, target: nil, action: nil)
            b.bezelStyle = .rounded
            b.isEnabled = false
            b.toolTip = "Back and Forward keep ⌘[ and ⌘]"
            rows.append([NSTextField(labelWithString: title), b])
        }
        message.textColor = .systemRed
        message.lineBreakMode = .byWordWrapping
        message.preferredMaxLayoutWidth = 420
        let stack = NSStackView(views: [settingsGrid(rows), message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        pinTopLeading(stack, in: self, inset: 0)
        NotificationCenter.default.addObserver(self, selector: #selector(stopRecording),
                                               name: NSWindow.didResignKeyNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func show(_ bindings: KeyBindings) {
        for (action, b) in buttons where action != recording {
            b.title = bindings.combo(for: action)?.display ?? "None"
        }
    }

    @objc private func record(_ sender: NSButton) {
        stopRecording()
        let action = Action.allCases[sender.tag]
        recording = action
        sender.title = "Type a shortcut…"
        message.stringValue = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.keyCode == kVK_Escape { self.stopRecording() } else if let combo = KeyCombo(event: event) { self.bind(action, to: combo) }
            return nil
        }
    }

    private func bind(_ action: Action, to combo: KeyCombo) {
        var bindings = model.value.bindings
        if let holder = bindings.rebind(action, to: combo) {
            message.stringValue = "\(combo.display) is already the shortcut for \(holder.title)"
        } else if let item = Self.menuItem(using: combo) {
            message.stringValue = "\(combo.display) is already the shortcut for \(item.title) in the menu bar"
        } else {
            model.update { $0.bindings = bindings }
        }
        stopRecording()
    }

    @objc private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        show(model.value.bindings)
    }

    /// A main-menu item other than Next/Previous (which show the bindings themselves) whose shortcut is `combo`.
    private static func menuItem(using combo: KeyCombo) -> NSMenuItem? {
        func search(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let sub = item.submenu, let hit = search(sub) { return hit }
                let mine = item.action == #selector(MainWindowController.goNext(_:))
                    || item.action == #selector(MainWindowController.goPrevious(_:))
                if !mine, !item.keyEquivalent.isEmpty, item.keyEquivalent.lowercased() == combo.key,
                   item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == combo.modifierFlags {
                    return item
                }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }
}

// MARK: - Content blocking

/// A plain-text editor for the WebKit content-rule-list JSON. Save compiles it; a compile error shows here and
/// the previous rules stay active.
private final class ContentRulesPane: NSView {
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
        pinTopLeading(stack, in: self, inset: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows why the saved rules aren't active, if they aren't.
    func refreshStatus() {
        if let error = ContentRules.shared.error { setStatus(error, failed: true) }
    }

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

// MARK: - Layout helpers

private func settingsGrid(_ rows: [[NSView]]) -> NSGridView {
    let grid = NSGridView(views: rows)
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .firstBaseline
    grid.rowSpacing = 12
    grid.columnSpacing = 8
    return grid
}

private func pinTopLeading(_ child: NSView, in host: NSView, inset: CGFloat = 20) {
    child.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(child)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: inset),
        child.topAnchor.constraint(equalTo: host.topAnchor, constant: inset),
        child.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -inset),
        child.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -inset),
    ])
}
