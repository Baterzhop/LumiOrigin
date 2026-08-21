import XCTest
@testable import LumiClientCore

final class ConfigurationTests: XCTestCase {
    func testAcceptsLoopbackHTTP() throws {
        let url = try LumiClientConfiguration.validatedBaseURL("http://127.0.0.1:8790")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.port, 8790)
    }

    func testAcceptsRemoteHTTPS() throws {
        let url = try LumiClientConfiguration.validatedBaseURL("https://lumi.example.com")
        XCTAssertEqual(url.scheme, "https")
    }

    func testRejectsRemotePlainHTTP() {
        XCTAssertThrowsError(try LumiClientConfiguration.validatedBaseURL("http://lumi.example.com:8790"))
    }

    func testRejectsNonHTTPURL() {
        XCTAssertThrowsError(try LumiClientConfiguration.validatedBaseURL("file:///tmp/lumi"))
    }
}
