import Foundation
import XCTest
@testable import LumiCore

final class ToolHistoryPersistenceTests: XCTestCase {
    func testApprovedNativeToolCallPersistsProtocolHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiNativeHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("lumi.sqlite3")
        let conversationID = UUID()
        let broker = TestUserFileBroker()
        let resourceID = broker.register(
            content: "durable tool result",
            displayName: "fixture.txt"
        )

        let call = try ToolCall.encoding(
            name: "file.readText",
            version: "2",
            input: ReadTextFileInput(resourceID: resourceID),
            providerCallID: "call_persist_77"
        )
        let model = HistoryScriptedModel(turns: [
            .toolCall(call),
            .final("done")
        ])
        let store = try SQLiteConversationStore(url: databaseURL)
        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [AnyTool(ReadTextFileTool(broker: broker))])
        let runtime = AgentRuntime(
            store: store,
            model: model,
            toolRuntime: ToolRuntime(registry: registry, permissions: permissions)
        )

        let first = try await runtime.send("Read selected file", conversationID: conversationID)
        guard case .permissionRequired(let pending) = first else {
            return XCTFail("Native tool call must stop at permission boundary")
        }

        let approved = try await runtime.approvePermission(
            pendingID: pending.id,
            duration: .once
        )
        guard case .completed = approved else {
            return XCTFail("Approved tool call should complete")
        }

        let reopened = try SQLiteConversationStore(url: databaseURL)
        let loaded = try await reopened.loadConversation(id: conversationID)
        let restored = try XCTUnwrap(loaded)
        let toolMessage = try XCTUnwrap(restored.messages.first(where: { $0.role == .tool }))
        let data = try XCTUnwrap(toolMessage.content.data(using: .utf8))
        let event = try JSONDecoder().decode(ToolHistoryEvent.self, from: data)

        XCTAssertEqual(event.status, .success)
        XCTAssertEqual(event.providerCallID, "call_persist_77")
        XCTAssertEqual(event.tool, "file.readText")
        XCTAssertEqual(event.version, "2")
        XCTAssertEqual(
            event.arguments,
            .object([
                "resourceID": .string(resourceID.rawValue),
                "maxBytes": .number(Double(ReadTextFileInput.defaultMaxBytes))
            ])
        )
        guard case .object(let result) = event.data else {
            return XCTFail("Tool result must remain structured")
        }
        XCTAssertEqual(result["content"], .string("durable tool result"))
        XCTAssertEqual(result["resourceID"], .string(resourceID.rawValue))
        XCTAssertEqual(event.metadata["encoding"], .string("utf-8"))
        XCTAssertEqual(event.metadata["resourceID"], .string(resourceID.rawValue))
    }
}

private actor HistoryScriptedModel: ModelProvider {
    private var turns: [ModelTurn]

    init(turns: [ModelTurn]) {
        self.turns = turns
    }

    func respond(to request: ModelRequest) async throws -> ModelTurn {
        guard !turns.isEmpty else {
            throw HistoryScriptedModelError.noMoreTurns
        }
        return turns.removeFirst()
    }
}

private enum HistoryScriptedModelError: Error {
    case noMoreTurns
}
