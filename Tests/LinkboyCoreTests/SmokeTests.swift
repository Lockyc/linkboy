import XCTest
@testable import LinkboyCore

final class SmokeTests: XCTestCase {
    func testCoreLinks() {
        XCTAssertFalse(LinkboyCore.version.isEmpty)
    }
}
