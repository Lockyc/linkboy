import Foundation

/// The in-page half of the key rule, as JavaScript the app injects into every frame of every web view. A capturing
/// `keydown` listener checks an unmodified key against the bound page keys; if one matches and the deepest focused
/// element (through open shadow roots) isn't a text control, it cancels the key and posts its page key
/// (`KeyCombo.pageKey`) to the `messageName` handler.
public enum PageKeyScript {
    /// The `window.webkit.messageHandlers` name the listener posts to.
    public static let messageName = "linkboyKey"

    /// Sets the bound page keys (`KeyBindings.pageKeys`); safe to run again on a live page.
    public static func keys(_ keys: [String]) -> String {
        let list = (try? JSONEncoder().encode(keys)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "window.__linkboyKeys = new Set(\(list));"
    }

    /// Installs the listener once per frame; does nothing where the message handler is absent.
    public static let listener = #"""
    (() => {
        const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\#(messageName);
        if (!handler || window.__linkboyListening) return;
        window.__linkboyListening = true;
        const notText = new Set(["checkbox", "radio", "button", "submit", "reset", "range", "color", "file", "image", "hidden"]);
        const editable = (el) => {
            if (!el || el.nodeType !== 1) return false;
            if (el.isContentEditable) return true;
            if (el.tagName === "TEXTAREA" || el.tagName === "SELECT") return true;
            // `type` is normalised: lowercase, and "text" for a missing or unknown attribute.
            return el.tagName === "INPUT" && !notText.has(el.type);
        };
        const deepest = () => {
            let el = document.activeElement;
            while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
            return el;
        };
        window.addEventListener("keydown", (e) => {
            if (e.metaKey || e.ctrlKey || e.altKey || e.isComposing) return;
            const keys = window.__linkboyKeys;
            const name = (e.shiftKey ? "shift+" : "") + (e.key.length === 1 ? e.key.toLowerCase() : e.key);
            if (!keys || !keys.has(name) || editable(deepest())) return;
            e.preventDefault();
            e.stopImmediatePropagation();
            handler.postMessage(name);
        }, true);
    })();
    """#
}
