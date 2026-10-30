import AppKit
import Carbon.HIToolbox
import LinkboyCore

/// Settings ▸ Keys: one row per reading action with its shortcut and a button that records a new one. A shortcut
/// already held by another action or a menu item is refused with a message under the rows.
final class KeysPane: NSView {
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
        for (title, combo) in [("Back", MainWindowController.backKey), ("Forward", MainWindowController.forwardKey)] {
            let b = NSButton(title: combo.display, target: nil, action: nil)
            b.bezelStyle = .rounded
            b.isEnabled = false
            b.toolTip = "Back and Forward always use ⌘[ and ⌘]"
            rows.append([NSTextField(labelWithString: title), b])
        }
        message.textColor = .systemRed
        message.lineBreakMode = .byWordWrapping
        message.preferredMaxLayoutWidth = 420
        let stack = NSStackView(views: [settingsGrid(rows), message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        pinTopLeading(stack, in: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func show(_ bindings: KeyBindings) {
        for (action, b) in buttons where action != recording {
            b.title = bindings.combo(for: action)?.display ?? "None"
        }
    }

    /// Ends any recording in progress, keeping the action's current shortcut.
    func cancelRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        show(model.value.bindings)
    }

    @objc private func record(_ sender: NSButton) {
        cancelRecording()
        let action = Action.allCases[sender.tag]
        recording = action
        sender.title = "Type a shortcut…"
        message.stringValue = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.keyCode == kVK_Escape { self.cancelRecording() } else if let combo = KeyCombo(event: event) { self.bind(action, to: combo) }
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
        cancelRecording()
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
