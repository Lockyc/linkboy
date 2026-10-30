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

    private func url(_ text: String) -> Result<URL, ServerURLError> {
        Result { try Credentials.serverURL(from: text) }.mapError { $0 as! ServerURLError }
    }

    func testServerURLNormalisation() {
        XCTAssertEqual(url(" https://reader.example.com/ "), .success(URL(string: "https://reader.example.com")!))
        XCTAssertEqual(url("https://reader.example.com:8443/miniflux/?a=1#top"),
                       .success(URL(string: "https://reader.example.com:8443/miniflux")!))
        XCTAssertEqual(url("https://reader.example.com/v1/"), .success(URL(string: "https://reader.example.com")!))
        XCTAssertEqual(url("https://reader.example.com/miniflux/v1"), .success(URL(string: "https://reader.example.com/miniflux")!))
        XCTAssertEqual(url("https://reader.example.com/v1x"), .success(URL(string: "https://reader.example.com/v1x")!))
        XCTAssertEqual(url("reader.example.com"), .failure(.invalid))
        XCTAssertEqual(url("ftp://reader.example.com"), .failure(.invalid))
        XCTAssertEqual(url("https://"), .failure(.invalid))
        XCTAssertEqual(url(""), .failure(.invalid))
    }

    func testPlainHTTPOnlyForLocalServers() {
        for local in ["http://localhost:8080", "http://LOCALHOST/miniflux", "http://reader.local", "http://NAS.Local:8080",
                      "http://192.168.1.20:8080", "http://127.0.0.1", "http://[::1]:8080", "http://[fd00::12]/miniflux"] {
            XCTAssertEqual(url(local + "/v1/"), .success(URL(string: local)!), local)
        }
        for remote in ["http://reader.example.com", "HTTP://reader.example.com/v1/", "http://localhost.example.com",
                       "http://reader.local.example.com", "http://1.2.3.4.example.com", "http://192.168.1"] {
            XCTAssertEqual(url(remote), .failure(.insecure), remote)
        }
    }
}
