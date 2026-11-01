import AppKit
import LinkboyCore
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let updater = Updater.make()
    private let prefs = PreferencesModel()
    private var setup: SetupWindowController?
    private var main: MainWindowController?
    private var settings: SettingsWindowController?
    private var credentials: Credentials?
    private let nextItem = NSMenuItem(title: "Next", action: #selector(MainWindowController.goNext(_:)), keyEquivalent: "")
    private let previousItem = NSMenuItem(title: "Previous", action: #selector(MainWindowController.goPrevious(_:)),
                                          keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        ContentRules.shared.loadSaved()
        NSApp.mainMenu = makeMainMenu()
        prefs.observe { [weak self] in self?.showBindings($0.bindings) }
        do {
            if let saved = try CredentialStore.load() {
                do {
                    let c = Credentials(baseURL: try Credentials.serverURL(from: saved.baseURL.absoluteString), apiKey: saved.apiKey)
                    openMain(c, client: MinifluxClient(baseURL: c.baseURL, apiKey: c.apiKey))
                } catch {
                    credentials = saved
                    showSetup(error: SetupWindowController.message(for: error as? ServerURLError ?? .invalid))
                }
            } else {
                showSetup(error: nil)
            }
        } catch {
            showSetup(error: "Couldn't read the saved login from the Keychain")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Brings setup forward; an already-open setup window is left as the user has it. `fromBackground` (a rejected
    /// key reported by sync) never pulls it forward: an open window only gets the message, a closed one opens
    /// without taking focus from the reading window.
    private func showSetup(error: String?, fromBackground: Bool = false) {
        if let setup, let window = setup.window, window.isVisible {
            if fromBackground {
                if let error { setup.showError(error) }
            } else {
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
        let setup = self.setup ?? SetupWindowController()
        self.setup = setup
        setup.onConnected = { [weak self] c, client in self?.connected(c, client: client) }
        setup.present(prefill: credentials, error: error, takeFocus: !fromBackground)
    }

    @objc private func changeServer(_ sender: Any?) { showSetup(error: nil) }

    private func connected(_ c: Credentials, client: MinifluxClient) {
        do {
            try CredentialStore.save(c)
        } catch {
            alert("Couldn't save the login to the Keychain", detail: "This connection lasts until linkboy quits.")
        }
        if let main {
            credentials = c
            main.attach(api: client, server: c.baseURL)
        } else {
            openMain(c, client: client)
        }
    }

    private func openMain(_ c: Credentials, client: MinifluxClient) {
        credentials = c
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
            let store = try Store(path: support.appendingPathComponent("linkboy/linkboy.sqlite"))
            let main = try MainWindowController(store: store, preferences: prefs)
            main.onUnauthorized = { [weak self] in
                self?.showSetup(error: "Miniflux rejected the API key", fromBackground: true)
            }
            self.main = main
            main.attach(api: client, server: c.baseURL)
            main.showWindow(nil)
        } catch {
            alert("Couldn't open the local cache", detail: error.localizedDescription)
            NSApp.terminate(nil)
        }
    }

    @objc private func showSettings(_ sender: Any?) {
        let settings = self.settings ?? SettingsWindowController(model: prefs)
        self.settings = settings
        settings.present()
    }

    private func alert(_ message: String, detail: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.window.animationBehavior = .none
        a.runModal()
    }

    /// The Go menu shows Next and Previous's bound keys; `menuHasKeyEquivalent` keeps them display-only.
    private func showBindings(_ bindings: KeyBindings) {
        for (item, action) in [(nextItem, Action.next), (previousItem, .previous)] {
            let combo = bindings.combo(for: action)
            item.keyEquivalent = combo?.key ?? ""
            item.keyEquivalentModifierMask = combo?.modifierFlags ?? []
        }
    }

    /// The Go menu's key equivalents are labels only: its keys act through the main window's key monitor alone,
    /// which knows when they must not (another window, a text field, typing in a page).
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool { false }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let host = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            host.submenu = menu
            main.addItem(host)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let settingsItem = item("Settings…", #selector(showSettings(_:)), ",")
        settingsItem.target = self
        let changeServerItem = item("Change Server…", #selector(changeServer(_:)))
        changeServerItem.target = self
        let updatesItem = item("Check for Updates…", nil)
        if let updater {
            updatesItem.target = updater
            updatesItem.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        } else {
            updatesItem.isEnabled = false
            updatesItem.toolTip = "Only the installed linkboy.app updates itself"
        }
        add("linkboy", [
            item("About linkboy", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            updatesItem,
            .separator(),
            settingsItem,
            changeServerItem,
            .separator(),
            item("Hide linkboy", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit linkboy", #selector(NSApplication.terminate(_:)), "q"),
        ])
        // The main window's undo manager names its action, so this reads "Undo Mark All" there.
        add("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let back = MainWindowController.backKey, forward = MainWindowController.forwardKey
        let sync = MainWindowController.syncKey
        add("Go", [
            nextItem,
            previousItem,
            .separator(),
            item("Back", #selector(MainWindowController.historyBack(_:)), back.key, back.modifierFlags),
            item("Forward", #selector(MainWindowController.historyForward(_:)), forward.key, forward.modifierFlags),
            .separator(),
            item("Sync Now", #selector(MainWindowController.syncNow(_:)), sync.key, sync.modifierFlags),
        ])
        main.items.last?.submenu?.delegate = self
        showBindings(prefs.value.bindings)
        // The main window titles this "Mark as Read" while the open item is unread.
        add("Item", [
            item("Mark as Unread", #selector(MainWindowController.toggleRead(_:))),
            .separator(),
            item("Mark All as Read…", #selector(MainWindowController.markAll(_:))),
        ])
        add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.windowsMenu = main.items.last?.submenu
        return main
    }
}
