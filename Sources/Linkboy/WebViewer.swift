import AppKit
import LinkboyCore
import WebKit

/// One logged-in web pane. Every web view shares the persistent `WKWebsiteDataStore.default()`, presents a
/// desktop Safari user agent, carries the content rules and runs `FocusProbe`. ⌘-clicked links open in the
/// default browser; other links, `target=_blank` included, stay in this viewer.
final class WebViewer: NSView, WKNavigationDelegate, WKUIDelegate {
    /// The bound unmodified keys every page cancels and reports (`KeyBindings.pageKeys`). Setting it updates live
    /// pages' main frames now; their subframes and every later page get it at load.
    static var pageKeys = KeyBindings.default.pageKeys {
        didSet {
            guard pageKeys != oldValue else { return }
            for viewer in live.allObjects { viewer.refreshPageKeys() }
        }
    }
    private static let live = NSHashTable<WebViewer>.weakObjects()

    /// A bound key pressed while this viewer's page had keyboard focus outside any text control.
    var onPageKey: ((KeyCombo) -> Void)?

    private var webView: WKWebView
    /// Whether the current web view has committed its first page; until then the viewer itself holds the keyboard,
    /// so reading keys keep going through the app rather than into a page with no listener yet.
    private var committed = false

    init() {
        webView = Self.makeWebView()
        super.init(frame: .zero)
        install(webView)
        Self.live.add(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }

    /// Swaps in a fresh, blank web view, dropping the old one with its history. If the old view had keyboard focus,
    /// the viewer keeps it and hands it to the new page once that page commits.
    func resetHistory() {
        let hadFocus = containsFirstResponder
        tearDown(webView)
        webView = Self.makeWebView()
        committed = false
        install(webView)
        if hadFocus { window?.makeFirstResponder(self) }
    }

    /// Releases the page for good; the viewer is left blank and is not used again.
    func discard() { tearDown(webView) }

    private func tearDown(_ old: WKWebView) {
        old.stopLoading()
        old.configuration.userContentController.removeScriptMessageHandler(forName: FocusProbe.message,
                                                                           contentWorld: FocusProbe.world)
        old.navigationDelegate = nil
        old.uiDelegate = nil
        old.removeFromSuperview()
    }

    /// Gives this viewer keyboard focus: its page once committed, otherwise the viewer itself.
    func takeFocus() { window?.makeFirstResponder(committed ? webView : self) }

    var url: URL? { webView.url }
    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    var containsFirstResponder: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    /// The page itself holds keyboard focus, so its listener decides what unmodified keys do.
    var pageHasKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: webView)
    }

    // MARK: - Construction

    private func install(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
        view.configuration.userContentController.add(KeyHandler(self), contentWorld: FocusProbe.world, name: FocusProbe.message)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = safariToken
        config.mediaTypesRequiringUserActionForPlayback = .all
        addScripts(to: config.userContentController)
        ContentRules.shared.attach(config.userContentController)
        return WKWebView(frame: .zero, configuration: config)
    }

    private static func addScripts(to controller: WKUserContentController) {
        for source in [FocusProbe.keysScript(pageKeys), FocusProbe.listener] {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                                                  in: FocusProbe.world))
        }
    }

    private func refreshPageKeys() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        Self.addScripts(to: controller)
        webView.evaluateJavaScript(FocusProbe.keysScript(Self.pageKeys), in: nil, in: FocusProbe.world, completionHandler: nil)
    }

    /// Appended to WKWebView's own `Mozilla/5.0 (Macintosh; …) AppleWebKit/605.1.15 (KHTML, like Gecko)`, which
    /// lacks the `Version/… Safari/…` token sites check for a supported browser. The version is the installed
    /// Safari's, so it tracks macOS updates instead of going stale.
    private static let safariToken: String = {
        let raw = Bundle(path: "/Applications/Safari.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let parts = (raw ?? "").split(separator: ".").prefix(2).map { UInt($0) }
        let version = parts.first.flatMap { $0 }.map { major in "\(major).\(parts.dropFirst().first.flatMap { $0 } ?? 0)" }
        return "Version/\(version ?? "26.0") Safari/605.1.15"
    }()

    // MARK: - Page keys

    fileprivate func pageKeyPressed(_ name: String, from view: WKWebView?) {
        guard view === webView, let combo = KeyCombo(pageKey: name) else { return }
        onPageKey?(combo)
    }

    // MARK: - WKNavigationDelegate / WKUIDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        committed = true
        if window?.firstResponder === self { window?.makeFirstResponder(webView) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let handled = route(navigationAction, opensNewWindow: navigationAction.targetFrame == nil, in: webView)
        decisionHandler(handled ? .cancel : .allow)
    }

    /// `window.open` (and any `target=_blank` link the policy check let through) — never a new web view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        _ = route(navigationAction, opensNewWindow: true, in: webView)
        return nil
    }

    /// Carries out `LinkPolicy`'s decision; true when the original navigation should be cancelled.
    private func route(_ action: WKNavigationAction, opensNewWindow: Bool, in webView: WKWebView) -> Bool {
        switch LinkPolicy.decide(command: action.modifierFlags.contains(.command),
                                 linkActivated: action.navigationType == .linkActivated,
                                 opensNewWindow: opensNewWindow, url: action.request.url) {
        case .openExternally:
            if let url = action.request.url { NSWorkspace.shared.open(url) }
            return true
        case .loadHere:
            webView.load(action.request)
            return true
        case .ignore:
            return true
        case .allow:
            return false
        }
    }
}

/// Forwards page keys without the user content controller retaining the viewer.
private final class KeyHandler: NSObject, WKScriptMessageHandler {
    private weak var viewer: WebViewer?

    init(_ viewer: WebViewer) { self.viewer = viewer }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let name = message.body as? String else { return }
        viewer?.pageKeyPressed(name, from: message.webView)
    }
}
