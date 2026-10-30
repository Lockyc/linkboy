import WebKit

/// The script that lets reading keys work while a page has keyboard focus without stealing typing. It runs in every
/// frame, in linkboy's own content world (the page can't see or call it). A capturing `keydown` listener checks an
/// unmodified key against the bound page keys; if one matches and the deepest focused element (through open shadow
/// roots) isn't a text control, it cancels the key and posts its page key to the app.
enum FocusProbe {
    static let world = WKContentWorld.world(name: "linkboy")
    static let message = "linkboyKey"

    /// Sets the bound page keys (`KeyBindings.pageKeys`); safe to run again on a live page.
    static func keysScript(_ keys: [String]) -> String {
        let list = (try? JSONEncoder().encode(keys)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "window.__linkboyKeys = new Set(\(list));"
    }

    static let listener = #"""
    (() => {
        const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.linkboyKey;
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
