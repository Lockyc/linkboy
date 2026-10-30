import XCTest
@testable import LinkboyCore

final class CredentialsTests: XCTestCase {
    private var savedService: String!

    override func setUpWithError() throws {
        savedService = CredentialStore.service
        CredentialStore.service = "com.lockyc.linkboy.tests.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        try? CredentialStore.clear()
        CredentialStore.service = savedService
    }

    func testCredentialsRoundTrip() throws {
        XCTAssertNil(try CredentialStore.load())
        let first = Credentials(baseURL: URL(string: "https://reader.example.com")!, apiKey: "key-1")
        try CredentialStore.save(first)
        XCTAssertEqual(try CredentialStore.load(), first)

        let second = Credentials(baseURL: URL(string: "https://other.example.com/miniflux")!, apiKey: "key-2")
        try CredentialStore.save(second)
        XCTAssertEqual(try CredentialStore.load(), second)

        try CredentialStore.clear()
        XCTAssertNil(try CredentialStore.load())
    }

    func testSaveOverwritesSameServerAndLeavesOneItem() throws {
        let url = URL(string: "https://reader.example.com")!
        try CredentialStore.save(Credentials(baseURL: url, apiKey: "old"))
        try CredentialStore.save(Credentials(baseURL: url, apiKey: "new"))
        XCTAssertEqual(try CredentialStore.load(), Credentials(baseURL: url, apiKey: "new"))
        try CredentialStore.save(Credentials(baseURL: URL(string: "https://other.example.com")!, apiKey: "k"))
        XCTAssertEqual(try CredentialStore.itemCount(), 1)
    }

    func testServerURLNormalisation() {
        XCTAssertEqual(Credentials.serverURL(from: " https://reader.example.com/ "), URL(string: "https://reader.example.com"))
        XCTAssertEqual(Credentials.serverURL(from: "http://reader.example.com:8080/miniflux/?a=1#top"),
                       URL(string: "http://reader.example.com:8080/miniflux"))
        XCTAssertEqual(Credentials.serverURL(from: "https://reader.example.com/v1/"), URL(string: "https://reader.example.com"))
        XCTAssertEqual(Credentials.serverURL(from: "https://reader.example.com/miniflux/v1"),
                       URL(string: "https://reader.example.com/miniflux"))
        XCTAssertEqual(Credentials.serverURL(from: "https://reader.example.com/v1x"), URL(string: "https://reader.example.com/v1x"))
        XCTAssertNil(Credentials.serverURL(from: "reader.example.com"))
        XCTAssertNil(Credentials.serverURL(from: "ftp://reader.example.com"))
        XCTAssertNil(Credentials.serverURL(from: "https://"))
        XCTAssertNil(Credentials.serverURL(from: ""))
    }
}
