import XCTest
@testable import LinkboyCore

final class KeyRouterTests: XCTestCase {
    private let j = KeyCombo(key: "j")
    private let k = KeyCombo(key: "k")

    func testDefaultsRouteJAndK() {
        XCTAssertEqual(KeyRouter.route(j, editableFocused: false, bindings: .default), .next)
        XCTAssertEqual(KeyRouter.route(k, editableFocused: false, bindings: .default), .previous)
        XCTAssertEqual(KeyRouter.route(KeyCombo(key: "c"), editableFocused: false, bindings: .default), .togglePane)
        XCTAssertEqual(KeyRouter.route(KeyCombo(key: "s"), editableFocused: false, bindings: .default), .star)
        XCTAssertEqual(KeyRouter.route(KeyCombo(key: "o"), editableFocused: false, bindings: .default), .openInBrowser)
        XCTAssertEqual(KeyRouter.route(KeyCombo(key: "u"), editableFocused: false, bindings: .default), .toggleRead)
    }

    func testUnmodifiedKeysSuppressedWhileEditing() {
        XCTAssertNil(KeyRouter.route(j, editableFocused: true, bindings: .default))
        // ⇧ alone is still typing.
        var bindings = KeyBindings.default
        let shiftJ = KeyCombo(key: "j", modifiers: [.shift])
        XCTAssertNil(bindings.rebind(.next, to: shiftJ))
        XCTAssertNil(KeyRouter.route(shiftJ, editableFocused: true, bindings: bindings))
        XCTAssertEqual(KeyRouter.route(shiftJ, editableFocused: false, bindings: bindings), .next)
    }

    func testModifiedComboRoutesWhileEditing() {
        var bindings = KeyBindings.default
        for mod in [Modifier.command, .control, .option] {
            let combo = KeyCombo(key: "j", modifiers: [mod, .shift])
            XCTAssertNil(bindings.rebind(.next, to: combo))
            XCTAssertEqual(KeyRouter.route(combo, editableFocused: true, bindings: bindings), .next, "\(mod)")
        }
    }

    func testReboundKeyRoutes() {
        var bindings = KeyBindings.default
        let n = KeyCombo(key: "n")
        XCTAssertNil(bindings.rebind(.next, to: n))
        XCTAssertEqual(KeyRouter.route(n, editableFocused: false, bindings: bindings), .next)
        XCTAssertNil(KeyRouter.route(j, editableFocused: false, bindings: bindings), "the old key is released")
        XCTAssertEqual(bindings.combo(for: .next), n)
    }

    func testUnboundKeyIsNil() {
        XCTAssertNil(KeyRouter.route(KeyCombo(key: "x"), editableFocused: false, bindings: .default))
        XCTAssertNil(KeyRouter.route(KeyCombo(key: "j", modifiers: [.command]), editableFocused: false, bindings: .default))
    }

    func testRebindRejectsAComboHeldByAnotherAction() {
        var bindings = KeyBindings.default
        XCTAssertEqual(bindings.rebind(.next, to: k), .previous)
        XCTAssertEqual(bindings, .default, "a rejected rebind changes nothing")
        XCTAssertNil(bindings.rebind(.next, to: j), "rebinding to its own combo is fine")
    }

    func testDefaultsBindEveryActionOnce() {
        for action in Action.allCases { XCTAssertNotNil(KeyBindings.default.combo(for: action), "\(action)") }
        XCTAssertEqual(KeyBindings.default.map.count, Action.allCases.count)
    }

    func testBindingsRoundTripThroughJSON() throws {
        var bindings = KeyBindings.default
        XCTAssertNil(bindings.rebind(.star, to: KeyCombo(key: "f", modifiers: [.command, .shift])))
        let data = try JSONEncoder().encode(bindings)
        XCTAssertEqual(try JSONDecoder().decode(KeyBindings.self, from: data), bindings)
    }

    func testDecodedBindingsGainANewActionOnItsFreeDefaultCombo() throws {
        var saved = KeyBindings.default
        saved.map = saved.map.filter { $0.value != .toggleRead }
        let decoded = try JSONDecoder().decode(KeyBindings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, .default)
    }

    func testDecodedBindingsLeaveANewActionUnboundWhenItsDefaultComboIsTaken() throws {
        var saved = KeyBindings.default
        saved.map = saved.map.filter { $0.value != .toggleRead }
        XCTAssertNil(saved.rebind(.star, to: KeyCombo(key: "u")))
        let decoded = try JSONDecoder().decode(KeyBindings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, saved)
        XCTAssertNil(decoded.combo(for: .toggleRead))
    }
}
