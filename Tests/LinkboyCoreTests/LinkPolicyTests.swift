import XCTest
@testable import LinkboyCore

final class LinkPolicyTests: XCTestCase {
    func testCommandClickOpensExternally() {
        XCTAssertEqual(LinkPolicy.decide(command: true, linkActivated: true, opensNewWindow: false), .openExternally)
    }

    func testPlainClickStaysInTheViewer() {
        XCTAssertEqual(LinkPolicy.decide(command: false, linkActivated: true, opensNewWindow: false), .allow)
    }

    func testBlankTargetLoadsHereWithoutCommand() {
        XCTAssertEqual(LinkPolicy.decide(command: false, linkActivated: true, opensNewWindow: true), .loadHere)
        XCTAssertEqual(LinkPolicy.decide(command: false, linkActivated: false, opensNewWindow: true), .loadHere,
                       "window.open")
    }

    func testBlankTargetWithCommandOpensExternally() {
        XCTAssertEqual(LinkPolicy.decide(command: true, linkActivated: true, opensNewWindow: true), .openExternally)
        XCTAssertEqual(LinkPolicy.decide(command: true, linkActivated: false, opensNewWindow: true), .openExternally)
    }

    func testCommandOnANonLinkNavigationIsAllowed() {
        // A redirect, reload or form submission while ⌘ happens to be held stays in the viewer.
        XCTAssertEqual(LinkPolicy.decide(command: true, linkActivated: false, opensNewWindow: false), .allow)
    }
}
