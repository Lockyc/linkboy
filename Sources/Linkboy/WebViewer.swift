import AppKit
import LinkboyCore
import WebKit

/// One logged-in web pane. Every web view shares the persistent `WKWebsiteDataStore.default()`, presents a
/// desktop Safari user agent and carries the content rules. ⌘-clicked links open in the default browser;
/// other links, `target=_blank` included, stay in this viewer.
final class WebViewer: NSView, WKNavigationDelegate, WKUIDelegate {
    static let focusMessage = "linkboyFocus"

    private(set) var webView: WKWebView
    /// True while the page's last focus report says a text field, text area, select or editable element has focus.
    private(set) var editableFocused = false

    init() {
        webView = Self.makeWebView()
        super.init(frame: .zero)
        install(webView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }

    /// Swaps in a fresh, blank web view, dropping the old one with its history. Keyboard focus, if the old
    /// view had it, moves to the new one.
    func resetHistory() {
        let old = webView
        let hadFocus = containsFirstResponder
        old.stopLoading()
        old.configuration.userContentController.removeScriptMessageHandler(forName: Self.focusMessage)
        old.navigationDelegate = nil
        old.uiDelegate = nil
        old.removeFromSuperview()
        webView = Self.makeWebView()
        editableFocused = false
        install(webView)
        if hadFocus { window?.makeFirstResponder(webView) }
    }

    var url: URL? { webView.url }

    var containsFirstResponder: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    // MARK: - Construction

    private func install(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
        view.configuration.userContentController.add(FocusHandler(self), name: Self.focusMessage)
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
        let controller = config.userContentController
        controller.addUserScript(WKUserScript(source: focusProbe, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ContentRules.shared.attach(controller)
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    private static let focusProbe: String = {
        guard let url = Bundle.main.url(forResource: "FocusProbe", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { fatalError("FocusProbe.js is missing from the app bundle's Resources") }
        return source
    }()

    /// Appended to WKWebView's own `Mozilla/5.0 (Macintosh; …) AppleWebKit/605.1.15 (KHTML, like Gecko)`, which
    /// lacks the `Version/… Safari/…` token sites check for a supported browser. The version is the installed
    /// Safari's, so it tracks macOS updates instead of going stale.
    private static let safariToken: String = {
        let raw = Bundle(path: "/Applications/Safari.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let parts = (raw ?? "").split(separator: ".").prefix(2).map { UInt($0) }
        let version = parts.first.flatMap { $0 }.map { major in "\(major).\(parts.dropFirst().first.flatMap { $0 } ?? 0)" }
        return "Version/\(version ?? "26.0") Safari/605.1.15"
    }()

    // MARK: - Focus reports

    fileprivate func focusReported(_ editable: Bool, from view: WKWebView?) {
        guard view === webView else { return }
        editableFocused = editable
    }

    // MARK: - WKNavigationDelegate / WKUIDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView { editableFocused = false }
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
                                 linkActivated: action.navigationType == .linkActivated, opensNewWindow: opensNewWindow) {
        case .openExternally:
            if let url = action.request.url { NSWorkspace.shared.open(url) }
            return true
        case .loadHere:
            webView.load(action.request)
            return true
        case .allow:
            return false
        }
    }
}

/// Forwards focus reports without the user content controller retaining the viewer.
private final class FocusHandler: NSObject, WKScriptMessageHandler {
    private weak var viewer: WebViewer?

    init(_ viewer: WebViewer) { self.viewer = viewer }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        viewer?.focusReported(message.body as? Bool ?? false, from: message.webView)
    }
}
