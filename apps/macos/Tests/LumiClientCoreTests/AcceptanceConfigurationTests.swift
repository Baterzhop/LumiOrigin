import XCTest
@testable import LumiClientCore

final class AcceptanceConfigurationTests: XCTestCase {
    func testArgumentsRequireModel() throws {
        let url = URL(string: "http://127.0.0.1:8790")!
        XCTAssertEqual(
            LumiAcceptanceConfiguration.arguments(baseURL: url, requireModel: true),
            ["acceptance", "--base-url", "http://127.0.0.1:8790", "--require-model"]
        )
    }

    func testEnvironmentUsesKeyWithoutLeakingItIntoArguments() throws {
        let environment = LumiAcceptanceConfiguration.environment(
            existing: ["PATH": "/usr/bin"],
            apiKey: "abcdefghijklmnopqrstuvwxyz"
        )
        XCTAssertEqual(environment["LUMI_API_KEY"], "abcdefghijklmnopqrstuvwxyz")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
    }

    func testDecodeReport() throws {
        let data = Data(
            """
            {
              "ok": true,
              "base_url": "http://127.0.0.1:8790",
              "require_model": true,
              "chat_provider": "ollama",
              "chat_model": "qwen3",
              "fallback": false,
              "stream_events": ["started", "delta", "completed"],
              "temporary_state_cleaned": true,
              "checks": {"health": true}
            }
            """.utf8
        )
        let report = try LumiAcceptanceConfiguration.decodeReport(data)
        XCTAssertTrue(report.ok)
        XCTAssertTrue(report.requireModel)
        XCTAssertFalse(report.fallback)
        XCTAssertEqual(report.chatProvider, "ollama")
        XCTAssertEqual(report.chatModel, "qwen3")
        XCTAssertEqual(report.streamEvents.last, "completed")
        XCTAssertTrue(report.temporaryStateCleaned)
    }
}
