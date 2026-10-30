// Tells the app whether a text-entry element has focus in this frame, so reading keys never steal
// the user's typing. Injected at document start into every frame; posts true/false to `linkboyFocus`.
(() => {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.linkboyFocus;
    if (!handler) return;
    const editable = (el) => {
        if (!el || el.nodeType !== 1) return false;
        if (el.isContentEditable) return true;
        const tag = el.tagName;
        return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";
    };
    // composedPath()[0] reaches the real element inside a shadow root, where `target` is the host.
    document.addEventListener("focusin", (e) => handler.postMessage(editable(e.composedPath()[0])), true);
    document.addEventListener("focusout", () => handler.postMessage(false), true);
})();
