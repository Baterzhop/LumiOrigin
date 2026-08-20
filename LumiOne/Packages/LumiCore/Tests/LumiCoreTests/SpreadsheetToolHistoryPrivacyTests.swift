import Foundation
import XCTest
@testable import LumiCore

final class SpreadsheetToolHistoryPrivacyTests: XCTestCase {
    func testSpreadsheetPreviewIsTransientForCurrentTurnAndRedactedFromDurableHistory() async throws {
        let secret = "SPREADSHEET-SECRET-ROW"
        let broker = TestUserFileBroker()
        let resourceID = broker.register(
            content: "name,note\nAlice,\(secret)\nBob,ordinary\n",
            displayName: "private.csv"
        )
        let call = try ToolCall.encoding(
            name: "spreadsheet.inspect",
            version: "1",
            input: SpreadsheetInspectInput(
                resourceID: resourceID,
                previewRows: 2
            ),
            providerCallID: "spreadsheet-call-1"
        )

        let model = SpreadsheetHistoryScriptedModel(turns: [
            .toolCall(call),
            .final("I inspected the bounded table preview."),
            .final("Follow-up answer.")
        ])
        let conversations = SpreadsheetHistoryConversationStore()
        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [
            AnyTool(SpreadsheetInspectTool(broker: broker))
        ])
        let tools = ToolRuntime(registry: registry, permissions: permissions)
        let runtime = AgentRuntime(
            store: conversations,
            model: model,
            toolRuntime: tools
        )
        let conversationID = UUID()

        let first = try await runtime.send(
            "Inspect my selected table.",
            conversationID: conversationID
        )
        guard case .permissionRequired(let pending) = first else {
            return XCTFail("Spreadsheet inspection must pause for selected-file permission")
        }

        let completed = try await runtime.approvePermission(
            pendingID: pending.id,
            duration: .once
        )
        guard case .completed = completed else {
            return XCTFail("Approved inspection should resume the current turn")
        }

        let requestsAfterTool = await model.requests()
        XCTAssertEqual(requestsAfterTool.count, 2)

        let currentTurnToolMessage = try XCTUnwrap(
            requestsAfterTool[1].messages.last(where: { $0.role == .tool })
        )
        XCTAssertTrue(currentTurnToolMessage.content.contains(secret))
        let currentTurnEvent = try decodeEvent(currentTurnToolMessage)
        XCTAssertEqual(currentTurnEvent.providerCallID, "spreadsheet-call-1")
        let currentTurnData = try XCTUnwrap(currentTurnEvent.data)
        let currentTurnJSON = try jsonString(currentTurnData)
        XCTAssertTrue(currentTurnJSON.contains(secret))
        XCTAssertFalse(currentTurnJSON.contains("<redacted:spreadsheet-preview>"))

        let durable = try await conversations.loadConversation(id: conversationID)
        let durableToolMessage = try XCTUnwrap(
            durable?.messages.last(where: { $0.role == .tool })
        )
        XCTAssertFalse(durableToolMessage.content.contains(secret))
        XCTAssertTrue(durableToolMessage.content.contains("<redacted:spreadsheet-preview>"))
        let durableEvent = try decodeEvent(durableToolMessage)
        XCTAssertEqual(durableEvent.callID, call.id)
        XCTAssertEqual(durableEvent.providerCallID, call.providerCallID)

        // A brand-new user turn receives only the durable representation. The
        // transient full preview is deliberately scoped to the prior turn.
        _ = try await runtime.send(
            "What should I check next?",
            conversationID: conversationID
        )

        let allRequests = await model.requests()
        XCTAssertEqual(allRequests.count, 3)
        let nextTurnHistory = allRequests[2].messages
            .filter { $0.role == .tool }
            .map(\.content)
            .joined(separator: "\n")
        XCTAssertFalse(nextTurnHistory.contains(secret))
        XCTAssertTrue(nextTurnHistory.contains("<redacted:spreadsheet-preview>"))
    }

    func testSpreadsheetProfileKeepsFullDerivedProfileEphemeralButDurableOutputIsStructural() async throws {
        let broker = TestUserFileBroker()
        let resourceID = broker.register(
            content: "private_column,score\nSECRET-VALUE,10\nOTHER,20\n",
            displayName: "profile-private.csv"
        )
        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [
            AnyTool(SpreadsheetProfileTool(broker: broker))
        ])
        let runtime = ToolRuntime(registry: registry, permissions: permissions)
        let call = try ToolCall.encoding(
            name: "spreadsheet.profile",
            version: "1",
            input: SpreadsheetProfileInput(resourceID: resourceID)
        )

        let pending = try await runtime.execute(call)
        guard case .permissionRequired(let request) = pending else {
            return XCTFail("Expected exact user-file permission")
        }
        _ = await runtime.grant(request, duration: .once)
        let executed = try await runtime.execute(call)
        guard case .success(let success) = executed else {
            return XCTFail("Expected successful profile")
        }

        let ephemeral = try jsonString(success.data)
        let durable = try jsonString(success.historyData)
        XCTAssertTrue(ephemeral.contains("private_column"))
        XCTAssertTrue(ephemeral.contains("numericCount"))
        XCTAssertFalse(durable.contains("private_column"))
        XCTAssertTrue(durable.contains("<redacted:spreadsheet-derived-profiles>"))
    }

    private func decodeEvent(_ message: ChatMessage) throws -> ToolHistoryEvent {
        let data = try XCTUnwrap(message.content.data(using: .utf8))
        return try JSONDecoder().decode(ToolHistoryEvent.self, from: data)
    }

    private func jsonString(_ value: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

private actor SpreadsheetHistoryScriptedModel: ModelProvider {
    private var turns: [ModelTurn]
    private var captured: [ModelRequest] = []

    init(turns: [ModelTurn]) {
        self.turns = turns
    }

    func respond(to request: ModelRequest) async throws -> ModelTurn {
        captured.append(request)
        guard !turns.isEmpty else {
            throw SpreadsheetHistoryTestError.noTurn
        }
        return turns.removeFirst()
    }

    func requests() -> [ModelRequest] {
        captured
    }
}

private actor SpreadsheetHistoryConversationStore: ConversationStore {
    private var conversations: [UUID: Conversation] = [:]

    func loadConversation(id: UUID) async throws -> Conversation? {
        conversations[id]
    }

    func saveConversation(_ conversation: Conversation) async throws {
        conversations[conversation.id] = conversation
    }
}

private enum SpreadsheetHistoryTestError: Error {
    case noTurn
}
