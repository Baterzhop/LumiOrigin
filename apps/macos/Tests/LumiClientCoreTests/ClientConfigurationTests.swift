import Foundation
import XCTest
@testable import LumiClientCore

final class ClientConfigurationTests: XCTestCase {
    func testNormalizesLoopbackOriginAndRejectsPathsOrCredentials() throws {
        XCTAssertEqual(
            LumiClientConfiguration.normalizedBaseURL(" http://127.0.0.1:8790/ ")?.absoluteString,
            "http://127.0.0.1:8790"
        )
        XCTAssertNil(LumiClientConfiguration.normalizedBaseURL("file:///tmp/lumi"))
        XCTAssertNil(LumiClientConfiguration.normalizedBaseURL("http://127.0.0.1:8790/v1"))
        XCTAssertNil(LumiClientConfiguration.normalizedBaseURL("http://user:pass@127.0.0.1:8790"))
    }

    func testPersistsBaseURLInIsolatedDefaults() throws {
        let suite = "LumiClientCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        try LumiClientConfiguration.setBaseURL("https://localhost:9443/", defaults: defaults)
        XCTAssertEqual(LumiClientConfiguration.baseURL(defaults: defaults).absoluteString, "https://localhost:9443")
    }
}
