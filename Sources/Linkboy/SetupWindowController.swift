import AppKit
import LinkboyCore

/// Server URL + API key, checked against Miniflux before they are kept.
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    /// Called once the server accepts the key, with the normalised credentials and a client for them.
    var onConnected: ((Credentials, MinifluxClient) -> Void)?

    private let urlField = NSTextField()
    private let keyField = NSSecureTextField()
    private let connect = NSButton(title: "Connect", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var attempt: Task<Void, Never>?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Connect to Miniflux"
        window.animationBehavior = .none
        super.init(window: window)
        window.delegate = self

        urlField.placeholderString = "https://miniflux.example.com"
        keyField.placeholderString = "API key"
        connect.keyEquivalent = "\r"
        connect.target = self
        connect.action = #selector(connectClicked)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Server URL"), urlField],
            [NSTextField(labelWithString: "API key"), keyField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        urlField.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let hint = NSTextField(wrappingLabelWithString: "Create an API key in Miniflux under Settings ▸ API Keys.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let buttons = NSStackView(views: [message, connect])
        buttons.orientation = .horizontal
        buttons.alignment = .firstBaseline
        message.setContentHuggingPriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [grid, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        hint.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.initialFirstResponder = urlField
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the window, prefilled, with `error` (if any) already in place. `takeFocus` false (a background event
    /// such as a rejected key) orders it in without making it key or activating the app, so reading carries on.
    func present(prefill: Credentials?, error: String?, takeFocus: Bool = true) {
        if let prefill {
            urlField.stringValue = prefill.baseURL.absoluteString
            keyField.stringValue = prefill.apiKey
        }
        show(error ?? "")
        window?.center()
        guard takeFocus else { window?.orderFront(nil); return }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Replaces the message line of the window as it stands, without moving or focusing it.
    func showError(_ text: String) { show(text) }

    static func message(for error: ServerURLError) -> String {
        switch error {
        case .invalid: return "Enter the server's full address, starting with https://"
        case .insecure: return "Use https:// — plain http is only allowed for local servers"
        }
    }

    @objc private func connectClicked() {
        let url: URL
        do {
            url = try Credentials.serverURL(from: urlField.stringValue)
        } catch {
            return show(Self.message(for: error as? ServerURLError ?? .invalid))
        }
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return show("Enter an API key") }
        let credentials = Credentials(baseURL: url, apiKey: key)
        let client = MinifluxClient(baseURL: url, apiKey: key)
        setBusy(true)
        attempt = Task { @MainActor [weak self] in
            let failure: String?
            do {
                _ = try await client.me()
                failure = nil
            } catch MinifluxError.unauthorized {
                failure = "Miniflux rejected the API key"
            } catch MinifluxError.transport {
                failure = "Couldn't reach \(url.host ?? url.absoluteString)"
            } catch MinifluxError.notFound {
                failure = "No Miniflux API at \(url.absoluteString)"
            } catch MinifluxError.http(let code) {
                failure = "The server answered with HTTP \(code)"
            } catch MinifluxError.decoding {
                failure = "The server's reply isn't from Miniflux"
            } catch {
                failure = error.localizedDescription
            }
            guard let self, !Task.isCancelled else { return }
            self.setBusy(false)
            if let failure {
                self.show(failure)
            } else {
                // Connected first, so on first run the main window exists before this, the only window, closes.
                self.onConnected?(credentials, client)
                self.close()
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        connect.isEnabled = !busy
        urlField.isEnabled = !busy
        keyField.isEnabled = !busy
        if busy { show("Connecting…", error: false) }
    }

    private func show(_ text: String, error: Bool = true) {
        message.stringValue = text
        message.textColor = error ? .systemRed : .secondaryLabelColor
    }

    func windowWillClose(_ notification: Notification) {
        attempt?.cancel()
        setBusy(false)
    }
}
