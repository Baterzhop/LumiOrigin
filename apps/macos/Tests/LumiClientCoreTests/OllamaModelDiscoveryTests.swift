import Foundation
import XCTest
@testable import LumiClientCore

final class OllamaModelDiscoveryTests: XCTestCase {
    func testListModelsUsesTagsEndpointAndSortsUniqueNames() async throws {
        let baseURL = URL(string: "http://127.0.0.1:11434")!
        let payload = Data(#"{"models":[{"name":"zeta:latest","model":"zeta:latest","size":200},{"name":"alpha:7b","model":"alpha:7b","size":100},{"name":"alpha:7b","model":"alpha:7b","size":100}]}"#.utf8)

        let client = OllamaModelDiscoveryClient(baseURL: baseURL) { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/tags")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (payload, response)
        }

        let models = try await client.listModels()
        XCTAssertEqual(models.map(\.name), ["alpha:7b", "zeta:latest"])
        XCTAssertEqual(models.first?.size, 100)
    }

    func testListModelsRejectsNonSuccessHTTPStatus() async {
        let baseURL = URL(string: "http://127.0.0.1:11434")!
        let client = OllamaModelDiscoveryClient(baseURL: baseURL) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        do {
            _ = try await client.listModels()
            XCTFail("Expected bad server response")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }
}
