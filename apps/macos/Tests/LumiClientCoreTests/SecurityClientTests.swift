import Foundation
import XCTest
@testable import LumiClientCore

final class SecurityClientTests: XCTestCase {
    func testAPIKeyIsAddedToRequests() throws {
        let key = String(repeating: "k", count: 32)
        let client = LumiAPIClient(baseURL: URL(string: "http://127.0.0.1:8790")!, apiKey: key)
        let request = client.makeRequest(URL(string: "http://127.0.0.1:8790/v1/runtime")!)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Lumi-Key"), key)
    }

    func testNoAuthorizationHeaderWhenKeyIsAbsent() throws {
        let client = LumiAPIClient(baseURL: URL(string: "http://127.0.0.1:8790")!, apiKey: "")
        let request = client.makeRequest(URL(string: "http://127.0.0.1:8790/health")!)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Lumi-Key"))
    }
}
