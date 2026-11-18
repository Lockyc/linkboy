import XCTest

/// `Support/Info.plist` is the bundle template `just bundle` copies; these are the keys a template edit can mangle
/// without anything failing until an update check goes nowhere.
final class InfoPlistTests: XCTestCase {
    private func plist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testFeedURLIsThisRepositorysLatestReleaseAppcast() throws {
        let p = try plist()
        let feed = try XCTUnwrap((p["SUFeedURL"] as? String).flatMap(URL.init(string:)))
        XCTAssertEqual(feed.scheme, "https")
        XCTAssertEqual(feed.host, "github.com")
        let segments = feed.pathComponents.filter { $0 != "/" }
        XCTAssertEqual(segments.count, 6, feed.absoluteString)
        XCTAssertEqual(Array(segments.dropFirst(2)), ["releases", "latest", "download", "appcast.xml"])
        let repo = try XCTUnwrap(segments.dropFirst().first)
        XCTAssertEqual(repo, (p["CFBundleName"] as? String)?.lowercased(), "the feed names another repository")
        XCTAssertEqual(repo, (p["CFBundleExecutable"] as? String)?.lowercased())
    }

    func testPublicEDKeyIsAnEd25519Key() throws {
        let key = try XCTUnwrap(try plist()["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32, "SUPublicEDKey is not 32 base64 bytes")
    }

    func testFixedBundleIdentity() throws {
        let p = try plist()
        XCTAssertEqual(p["CFBundleIdentifier"] as? String, "com.lockyc.linkboy")
        XCTAssertEqual(p["CFBundleExecutable"] as? String, "Linkboy")
        XCTAssertEqual(p["CFBundleName"] as? String, "linkboy")
    }
}
