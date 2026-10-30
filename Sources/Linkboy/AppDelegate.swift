import AppKit
import LinkboyCore

final class AppDelegate: NSObject, NSApplicationDelegate {
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
            if let saved = try CredentialStore.load(), let url = Credentials.serverURL(from: saved.baseURL.absoluteString) {
                let c = Credentials(baseURL: url, apiKey: saved.apiKey)
                openMain(c, client: MinifluxClient(baseURL: c.baseURL, apiKey: c.apiKey))
            } else {
                showSetup(error: nil)
            }
        } catch {
            showSetup(error: "Couldn't read the saved login from the Keychain")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Brings setup forward; an already-open setup window is left as the user has it.
    private func showSetup(error: String?) {
        if let window = setup?.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let setup = self.setup ?? SetupWindowController()
        self.setup = setup
        setup.onConnected = { [weak self] c, client in self?.connected(c, client: client) }
        setup.present(prefill: credentials, error: error)
    }

    @objc private func changeServer(_ sender: Any?) { showSetup(error: nil) }

    private func connected(_ c: Credentials, client: MinifluxClient) {
        do {
            try CredentialStore.save(c)
        } catch {
            alert("Couldn't save the login to the Keychain", detail: "This connection lasts until linkboy quits.")
        }
        if let main {
            let newServer = c.baseURL != credentials?.baseURL
            credentials = c
            main.attach(api: client, newServer: newServer)
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
            main.onUnauthorized = { [weak self] in self?.showSetup(error: "Miniflux rejected the API key") }
            self.main = main
            main.attach(api: client)
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

    /// The Go menu shows Next and Previous's bound keys. The main window's key monitor performs them before the
    /// menu sees the key, so they also work while a web page has focus.
    private func showBindings(_ bindings: KeyBindings) {
        for (item, action) in [(nextItem, Action.next), (previousItem, .previous)] {
            let combo = bindings.combo(for: action)
            item.keyEquivalent = combo?.key ?? ""
            item.keyEquivalentModifierMask = combo?.modifierFlags ?? []
        }
    }

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
        add("linkboy", [
            item("About linkboy", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
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
        add("Go", [
            nextItem,
            previousItem,
            .separator(),
            item("Back", #selector(MainWindowController.historyBack(_:)), "["),
            item("Forward", #selector(MainWindowController.historyForward(_:)), "]"),
        ])
        showBindings(prefs.value.bindings)
        add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.windowsMenu = main.items.last?.submenu
        return main
    }
}
