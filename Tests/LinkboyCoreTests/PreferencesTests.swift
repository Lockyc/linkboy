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
}
