#if canImport(JavaScriptCore)
import JavaScriptCore
import XCTest
@testable import LinkboyCore

/// Runs `PageKeyScript` in JavaScriptCore against a minimal `window` / `document`: a capturing `addEventListener`,
/// a settable `activeElement`, and a message handler that records what is posted.
final class PageKeyScriptTests: XCTestCase {
    private var context: JSContext!
    private var jsError: String?

    private static let stub = """
    var posted = [];
    var listeners = [];
    var window = {
        webkit: { messageHandlers: { \(PageKeyScript.messageName): { postMessage: function (n) { posted.push(n); } } } },
        addEventListener: function (type, fn, capture) { listeners.push({ type: type, fn: fn, capture: capture }); }
    };
    var document = { activeElement: null };
    function el(tag, extra) {
        var o = { nodeType: 1, tagName: tag, isContentEditable: false, shadowRoot: null };
        for (var k in extra) o[k] = extra[k];
        return o;
    }
    function press(key, o) {
        var prevented = false;
        var e = { key: key, shiftKey: !!o.shift, metaKey: !!o.meta, ctrlKey: !!o.ctrl, altKey: !!o.alt,
                  isComposing: !!o.composing, preventDefault: function () { prevented = true; },
                  stopImmediatePropagation: function () {} };
        posted = [];
        listeners.forEach(function (l) { if (l.type === "keydown") l.fn(e); });
        if (posted.length !== (prevented ? 1 : 0)) throw new Error("posted without cancelling, or the reverse");
        return posted.length ? posted[0] : null;
    }
    """

    private var bindings: KeyBindings {
        var b = KeyBindings.default
        b.rebind(.star, to: KeyCombo(key: "s", modifiers: [.shift]))
        b.rebind(.openInBrowser, to: KeyCombo(key: "\r"))
        return b
    }

    override func setUpWithError() throws {
        context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { [weak self] _, value in self?.jsError = value?.toString() }
        context.evaluateScript(Self.stub)
        context.evaluateScript(PageKeyScript.keys(bindings.pageKeys))
        context.evaluateScript(PageKeyScript.listener)
        XCTAssertNil(jsError)
    }

    /// The page key posted for `key` with `focus` (a JS expression) as the focused element, or nil.
    private func press(_ key: String, focus: String = "null", _ options: String = "{}") -> String? {
        context.evaluateScript("document.activeElement = \(focus);")
        let result = context.evaluateScript("press(\(String(reflecting: key)), \(options))")
        XCTAssertNil(jsError, jsError ?? "")
        return result.flatMap { $0.isNull ? nil : $0.toString() }
    }

    func testInstallsOneCapturingKeydownListener() {
        XCTAssertEqual(context.evaluateScript("listeners.length").toInt32(), 1)
        XCTAssertTrue(context.evaluateScript("listeners[0].type === 'keydown' && listeners[0].capture === true").toBool())
        context.evaluateScript(PageKeyScript.listener)
        XCTAssertEqual(context.evaluateScript("listeners.length").toInt32(), 1, "a second injection must not add another")
    }

    func testBoundKeyOutsideTextIsPosted() {
        XCTAssertEqual(press("j"), "j")
        XCTAssertEqual(press("j", focus: "el('BODY')"), "j")
        XCTAssertEqual(press("J", focus: "el('A')", "{shift: true}"), nil, "⇧J is not bound")
        XCTAssertEqual(press("x"), nil, "x is not bound")
    }

    func testTextControlsKeepTheirKeys() {
        for focus in ["el('INPUT', {type: 'text'})", "el('INPUT', {type: 'search'})", "el('INPUT', {type: 'email'})",
                      "el('TEXTAREA')", "el('SELECT')", "el('DIV', {isContentEditable: true})"] {
            XCTAssertNil(press("j", focus: focus), focus)
        }
    }

    func testNonTextInputsPassKeys() {
        for focus in ["el('INPUT', {type: 'checkbox'})", "el('INPUT', {type: 'radio'})", "el('INPUT', {type: 'button'})",
                      "el('INPUT', {type: 'submit'})", "el('BUTTON')"] {
            XCTAssertEqual(press("j", focus: focus), "j", focus)
        }
    }

    func testFocusInsideOpenShadowRoot() {
        let host = "el('MY-WIDGET', {shadowRoot: {activeElement: %@}})"
        XCTAssertNil(press("j", focus: String(format: host, "el('INPUT', {type: 'text'})")))
        XCTAssertEqual(press("j", focus: String(format: host, "el('BUTTON')")), "j")
        XCTAssertEqual(press("j", focus: String(format: host, "null")), "j")
    }

    func testShiftAndNamedKeysMatchPageKeys() throws {
        let shifted = try XCTUnwrap(press("S", focus: "el('BODY')", "{shift: true}"))
        XCTAssertEqual(shifted, KeyCombo(key: "s", modifiers: [.shift]).pageKey)
        XCTAssertEqual(KeyCombo(pageKey: shifted), KeyCombo(key: "s", modifiers: [.shift]))
        XCTAssertNil(press("s"), "plain s was rebound away")
        let enter = try XCTUnwrap(press("Enter"))
        XCTAssertEqual(enter, KeyCombo(key: "\r").pageKey)
        XCTAssertEqual(KeyCombo(pageKey: enter), KeyCombo(key: "\r"))
    }

    func testComposingAndModifiedKeysAreNotPosted() {
        XCTAssertNil(press("j", "{composing: true}"))
        XCTAssertNil(press("j", "{meta: true}"))
        XCTAssertNil(press("j", "{ctrl: true}"))
        XCTAssertNil(press("j", "{alt: true}"))
    }
}
#endif
