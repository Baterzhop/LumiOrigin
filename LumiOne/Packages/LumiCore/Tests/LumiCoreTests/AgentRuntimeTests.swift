import Foundation
import XCTest
@testable import LumiCore

final class AgentRuntimeTests: XCTestCase {
    func testConversationSurvivesStoreReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiOneTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("lumi.sqlite3")
        let conversationID = UUID()

        do {
            let store = try SQLiteConversationStore(url: databaseURL)
            let runtime = AgentRuntime(store: store, model: TestModelProvider())
            let response = try await runtime.send("Remember this message", conversationID: conversationID)

            XCTAssertEqual(response.conversation.messages.count, 2)
            XCTAssertEqual(response.assistantMessage.content, "ACK: Remember this message")
        }

        let reopenedStore = try SQLiteConversationStore(url: databaseURL)
        let restored = try await reopenedStore.loadConversation(id: conversationID)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.messages.count, 2)
        XCTAssertEqual(restored?.messages.first?.content, "Remember this message")
        XCTAssertEqual(restored?.messages.last?.content, "ACK: Remember this message")
    }

    func testUserMessageRemainsDurableWhenModelFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiOneTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("lumi.sqlite3")
        let conversationID = UUID()
        let store = try SQLiteConversationStore(url: databaseURL)
        let runtime = AgentRuntime(store: store, model: FailingModelProvider())

        do {
            _ = try await runtime.send("Persist me before failure", conversationID: conversationID)
            XCTFail("Expected model failure")
        } catch {
            // Expected. Persistence is the behavior under test.
        }

        let reopenedStore = try SQLiteConversationStore(url: databaseURL)
        let restored = try await reopenedStore.loadConversation(id: conversationID)

        XCTAssertEqual(restored?.messages.count, 1)
        XCTAssertEqual(restored?.messages.first?.role, .user)
        XCTAssertEqual(restored?.messages.first?.content, "Persist me before failure")
    }

    func testStorageBootstrapReturnsSafeModeInsteadOfMemoryFallback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiOneTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let blockingFile = directory.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingFile)
        let impossibleDatabase = blockingFile.appendingPathComponent("lumi.sqlite3")

        switch StorageBootstrap.openSQLite(at: impossibleDatabase) {
        case .ready:
            XCTFail("Persistent storage failure must not silently fall back to an in-memory store")
        case .safeMode(let reason):
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testEmptyMessageIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiOneTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteConversationStore(url: directory.appendingPathComponent("lumi.sqlite3"))
        let runtime = AgentRuntime(store: store, model: TestModelProvider())

        do {
            _ = try await runtime.send("   ", conversationID: UUID())
            XCTFail("Expected empty input to fail")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.description, "Message cannot be empty.")
        }
    }
}

private struct TestModelProvider: ModelProvider {
    func respond(to request: ModelRequest) async throws -> ModelResponse {
        let lastUser = request.messages.last(where: { $0.role == .user })?.content ?? ""
        return ModelResponse(content: "ACK: \(lastUser)")
    }
}

private struct FailingModelProvider: ModelProvider {
    func respond(to request: ModelRequest) async throws -> ModelResponse {
        throw ExpectedFailure.modelUnavailable
    }
}

private enum ExpectedFailure: Error {
    case modelUnavailable
}
