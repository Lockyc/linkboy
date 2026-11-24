import XCTest
@testable import LinkboyCore

final class LinkPolicyTests: XCTestCase {
    private let page = URL(string: "https://example.com/a")!
    private let blank = URL(string: "about:blank")!

    func testCommandClickOpensExternally() {
        XCTAssertEqual(LinkPolicy.decide(command: true, linkActivated: true, opensNewWindow: false, url: page), .openExternally)
    }

    func testPlainClickStaysInTheViewer() {
        XCTAssertEqual(LinkPolicy.decide(command: false, linkActivated: true, opensNewWindow: false, url: page), .allow)
    }

    func testBlankTargetLoadsHereWithoutCommand() {
        XCTAssertEqual(LinkPolicy.decide(command: false, linkActivated: true, opensNewWindow: true, url: page), .loadHere)
        XCTAssertEqual(LinkPolicy.decide(command: false, linkActivated: false, opensNewWindow: true, url: page), .loadHere,
                       "window.open")
    }

    func testBlankTargetWithCommandOpensExternally() {
        XCTAssertEqual(LinkPolicy.decide(command: true, linkActivated: true, opensNewWindow: true, url: page), .openExternally)
        XCTAssertEqual(LinkPolicy.decide(command: true, linkActivated: false, opensNewWindow: true, url: page), .openExternally)
    }

    func testCommandOnANonLinkNavigationIsAllowed() {
        // A redirect, reload or form submission while ⌘ happens to be held stays in the viewer.
        XCTAssertEqual(LinkPolicy.decide(command: true, linkActivated: false, opensNewWindow: false, url: page), .allow)
    }

    func testEmptyPopupIsIgnored() {
        // window.open() / window.open("about:blank") with nothing to show replaces nothing and opens nothing.
        for command in [false, true] {
            XCTAssertEqual(LinkPolicy.decide(command: command, linkActivated: false, opensNewWindow: true, url: nil), .ignore)
            XCTAssertEqual(LinkPolicy.decide(command: command, linkActivated: false, opensNewWindow: true, url: blank), .ignore)
        }
    }

    func testAboutBlankInPlaceIsAllowed() {
        // Frames load about:blank all the time.
        XCTAssertEqual(LinkPolicy.decide(command: false, linkActivated: false, opensNewWindow: false, url: blank), .allow)
    }

    func testNonWebSchemeLinksGoToMacOS() {
        // A web view can't load these and does nothing with them, so a plain click would be a dead link.
        for raw in ["mailto:someone@example.com", "MAILTO:someone@example.com", "zoommtg://join?x=1"] {
            let url = URL(string: raw)!
            XCTAssertEqual(LinkPolicy.decide(command: false, linkActivated: true, opensNewWindow: false, url: url),
                           .openExternally, raw)
            XCTAssertEqual(LinkPolicy.decide(command: false, linkActivated: false, opensNewWindow: true, url: url),
                           .openExternally, raw)
        }
    }

    func testNonWebSchemeWithoutAUserActionStaysPut() {
        // A redirect or frame load to an app scheme isn't something the user clicked.
        let url = URL(string: "zoommtg://join?x=1")!
        XCTAssertEqual(LinkPolicy.decide(command: false, linkActivated: false, opensNewWindow: false, url: url), .allow)
    }

    func testWebSchemesStayInTheViewer() {
        for raw in ["http://example.com", "data:text/plain,hi", "blob:https://example.com/x", "javascript:void(0)"] {
            XCTAssertEqual(LinkPolicy.decide(command: false, linkActivated: true, opensNewWindow: false,
                                             url: URL(string: raw)!), .allow, raw)
        }
    }
}
