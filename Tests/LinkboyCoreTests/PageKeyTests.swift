import XCTest
@testable import LinkboyCore

final class PageKeyTests: XCTestCase {
    func testLettersAndShift() {
        XCTAssertEqual(KeyCombo(key: "j").pageKey, "j")
        XCTAssertEqual(KeyCombo(key: "j", modifiers: [.shift]).pageKey, "shift+j")
        XCTAssertEqual(KeyCombo(pageKey: "shift+j"), KeyCombo(key: "j", modifiers: [.shift]))
        XCTAssertEqual(KeyCombo(pageKey: "j"), KeyCombo(key: "j"))
    }

    func testSpecialKeysUseDOMNames() {
        let cases: [(String, String)] = [
            (" ", " "), ("\r", "Enter"), ("\t", "Tab"), ("\u{7f}", "Backspace"), ("\u{1b}", "Escape"),
            ("\u{F700}", "ArrowUp"), ("\u{F701}", "ArrowDown"), ("\u{F702}", "ArrowLeft"), ("\u{F703}", "ArrowRight"),
            ("\u{F704}", "F1"), ("\u{F70F}", "F12"),
        ]
        for (key, dom) in cases {
            XCTAssertEqual(KeyCombo(key: key).pageKey, dom, dom)
            XCTAssertEqual(KeyCombo(pageKey: dom), KeyCombo(key: key), dom)
        }
    }

    func testModifiedCombosHaveNoPageKey() {
        for mod in [Modifier.command, .control, .option] {
            XCTAssertNil(KeyCombo(key: "j", modifiers: [mod]).pageKey)
        }
    }

    func testBindingsPageKeysAreTheUnmodifiedOnes() {
        var bindings = KeyBindings.default
        XCTAssertEqual(bindings.pageKeys, ["c", "j", "k", "o", "s", "u"])
        bindings.rebind(.star, to: KeyCombo(key: "s", modifiers: [.command]))
        bindings.rebind(.next, to: KeyCombo(key: "\u{F701}", modifiers: [.shift]))
        XCTAssertEqual(bindings.pageKeys, ["c", "k", "o", "shift+ArrowDown", "u"])
    }
}
