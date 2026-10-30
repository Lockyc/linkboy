import AppKit
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
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
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
        window.delegate = self

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
        tabs.delegate = self
        for (title, view) in [("General", general), ("Keys", keys), ("Content Blocking", rules)] as [(String, NSView)] {
            let item = NSTabViewItem()
            item.label = title
            let host = NSView()
            pinTopLeading(view, in: host, inset: 20)
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

    // MARK: - A shortcut being recorded never outlives the Keys tab being in front of a key window.

    func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) { keys.cancelRecording() }

    func windowDidResignKey(_ notification: Notification) { keys.cancelRecording() }

    func windowWillClose(_ notification: Notification) { keys.cancelRecording() }
}

// MARK: - Layout helpers shared by the Settings tabs

func settingsGrid(_ rows: [[NSView]]) -> NSGridView {
    let grid = NSGridView(views: rows)
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .firstBaseline
    grid.rowSpacing = 12
    grid.columnSpacing = 8
    return grid
}

func pinTopLeading(_ child: NSView, in host: NSView, inset: CGFloat = 0) {
    child.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(child)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: inset),
        child.topAnchor.constraint(equalTo: host.topAnchor, constant: inset),
        child.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -inset),
        child.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -inset),
    ])
}
