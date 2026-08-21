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

    func testAcceptsHTTPSPathPrefix() throws {
        let url = try LumiClientConfiguration.validatedBaseURL("https://lumi.example.com/core")
        XCTAssertEqual(url.path, "/core")
    }

    func testRejectsRemotePlainHTTP() {
        XCTAssertThrowsError(try LumiClientConfiguration.validatedBaseURL("http://lumi.example.com:8790"))
    }

    func testRejectsNonHTTPURL() {
        XCTAssertThrowsError(try LumiClientConfiguration.validatedBaseURL("file:///tmp/lumi"))
    }

    func testRejectsEmbeddedCredentials() {
        XCTAssertThrowsError(try LumiClientConfiguration.validatedBaseURL("https://user:secret@lumi.example.com")) { error in
            guard case LumiClientConfiguration.ConfigurationError.embeddedCredentials = error else {
                return XCTFail("Expected embeddedCredentials, got \(error)")
            }
        }
    }

    func testRejectsQueryAndFragment() {
        XCTAssertThrowsError(try LumiClientConfiguration.validatedBaseURL("https://lumi.example.com?token=secret"))
        XCTAssertThrowsError(try LumiClientConfiguration.validatedBaseURL("https://lumi.example.com#fragment"))
    }
}
