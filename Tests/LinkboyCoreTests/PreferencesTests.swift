import XCTest
@testable import LinkboyCore

final class PreferencesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "linkboy-prefs-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testPreferencesDefaultsAndRoundTrip() {
        let fresh = Preferences.load(from: defaults)
        XCTAssertEqual(fresh, Preferences())
        XCTAssertEqual(fresh.layout, .single)
        XCTAssertEqual(fresh.listWidth, 320)
        XCTAssertEqual(fresh.splitFraction, 0.5)
        XCTAssertEqual(fresh.listFontSize, 13)
        XCTAssertEqual(fresh.density, .regular)

        var changed = fresh
        changed.layout = .sideBySide
        changed.listWidth = 400
        changed.splitFraction = 0.6
        changed.listFontSize = 15
        changed.density = .compact
        changed.save(to: defaults)
        XCTAssertEqual(Preferences.load(from: defaults), changed)
    }

    func testPreferencesDecodeWithoutBindingsKeepsOtherFields() throws {
        let saved = #"{"layout":"sideBySide","listWidth":410,"splitFraction":0.6,"listFontSize":15,"density":"compact"}"#
        defaults.set(Data(saved.utf8), forKey: Preferences.key)
        let prefs = Preferences.load(from: defaults)
        XCTAssertEqual(prefs.layout, .sideBySide)
        XCTAssertEqual(prefs.listWidth, 410)
        XCTAssertEqual(prefs.splitFraction, 0.6)
        XCTAssertEqual(prefs.listFontSize, 15)
        XCTAssertEqual(prefs.density, .compact)
        XCTAssertEqual(prefs.bindings, .default)
    }

    func testPreferencesDecodeFillsEachMissingFieldWithItsDefault() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(#"{"listWidth":250}"#.utf8))
        var expected = Preferences()
        expected.listWidth = 250
        XCTAssertEqual(prefs, expected)
    }

    func testBindingsRoundTripThroughPreferences() {
        var prefs = Preferences()
        XCTAssertNil(prefs.bindings.rebind(.next, to: KeyCombo(key: "n")))
        prefs.save(to: defaults)
        XCTAssertEqual(Preferences.load(from: defaults).bindings, prefs.bindings)
    }
}
