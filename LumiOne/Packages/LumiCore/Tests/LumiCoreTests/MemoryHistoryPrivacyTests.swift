import Foundation
import XCTest
@testable import LumiCore

final class MemoryHistoryPrivacyTests: XCTestCase {
    func testApprovedRememberPersistsRedactedToolProtocolHistory() async throws {
        let fixture = try MemoryHistoryFixture()
        defer { fixture.cleanup() }

        let secret = "SUPER-PRIVATE-MEMORY-VALUE-42"
        let call = try ToolCall.encoding(
            name: "memory.remember",
            version: "1",
            input: RememberMemoryInput(
                key: "private.preference",
                kind: .preference,
                value: secret,
                confidence: 1
            ),
            providerCallID: "memory-call-1"
        )
        let model = MemoryHistoryScriptedModel(turns: [
            .toolCall(call),
            .final("Memory saved.")
        ])
        let conversationStore = MemoryHistoryConversationStore()
        let runtime = AgentRuntime(
            store: conversationStore,
            model: model,
            toolRuntime: fixture.toolRuntime
        )
        let conversationID = UUID()

        let first = try await runtime.send(
            "Store the approved proposal.",
            conversationID: conversationID
        )
        guard case .permissionRequired(let pending) = first else {
            return XCTFail("Expected memory approval")
        }
        XCTAssertEqual(pending.permission.details["proposedValue"], secret)

        let completed = try await runtime.approvePermission(
            pendingID: pending.id,
            duration: .once
        )
        guard case .completed = completed else {
            return XCTFail("Expected completed memory round-trip")
        }

        let durable = try await conversationStore.loadConversation(id: conversationID)
        let toolMessage = try XCTUnwrap(durable?.messages.first(where: { $0.role == .tool }))
        XCTAssertFalse(toolMessage.content.contains(secret))
        XCTAssertTrue(toolMessage.content.contains("<redacted:persistent-memory-value>"))
        XCTAssertTrue(toolMessage.content.contains("private.preference"))
        XCTAssertTrue(toolMessage.content.contains("memory-call-1"))

        let stored = try await fixture.service.load(key: "private.preference")
        XCTAssertEqual(stored?.value, secret)
    }

    func testDeniedRememberAlsoPersistsOnlyRedactedArguments() async throws {
        let fixture = try MemoryHistoryFixture()
        defer { fixture.cleanup() }

        let secret = "DENIED-PRIVATE-MEMORY-VALUE"
        let call = try ToolCall.encoding(
            name: "memory.remember",
            version: "1",
            input: RememberMemoryInput(
                key: "private.denied",
                kind: .context,
                value: secret,
                confidence: 1
            ),
            providerCallID: "memory-call-denied"
        )
        let model = MemoryHistoryScriptedModel(turns: [
            .toolCall(call),
            .final("Memory was not saved.")
        ])
        let conversationStore = MemoryHistoryConversationStore()
        let runtime = AgentRuntime(
            store: conversationStore,
            model: model,
            toolRuntime: fixture.toolRuntime
        )
        let conversationID = UUID()

        let first = try await runtime.send(
            "Consider the proposed memory.",
            conversationID: conversationID
        )
        guard case .permissionRequired(let pending) = first else {
            return XCTFail("Expected memory approval")
        }

        let completed = try await runtime.denyPermission(pendingID: pending.id)
        guard case .completed = completed else {
            return XCTFail("Expected model continuation after denial")
        }

        let durable = try await conversationStore.loadConversation(id: conversationID)
        let toolMessage = try XCTUnwrap(durable?.messages.first(where: { $0.role == .tool }))
        XCTAssertFalse(toolMessage.content.contains(secret))
        XCTAssertTrue(toolMessage.content.contains("<redacted:persistent-memory-value>"))

        let stored = try await fixture.service.load(key: "private.denied")
        XCTAssertNil(stored)
    }
}

private final class MemoryHistoryFixture: @unchecked Sendable {
    let directory: URL
    let store: SQLiteMemoryStore
    let service: MemoryService
    let toolRuntime: ToolRuntime

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-memory-history-tests-\(UUID().uuidString)")
        store = try SQLiteMemoryStore(url: directory.appendingPathComponent("memory.sqlite3"))
        service = MemoryService(store: store)
        let registry = try ToolRegistry(tools: [
            AnyTool(RememberMemoryTool(service: service)),
            AnyTool(ForgetMemoryTool(service: service))
        ])
        toolRuntime = ToolRuntime(registry: registry, permissions: PermissionEngine())
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor MemoryHistoryScriptedModel: ModelProvider {
    private var turns: [ModelTurn]

    init(turns: [ModelTurn]) {
        self.turns = turns
    }

    func respond(to request: ModelRequest) async throws -> ModelTurn {
        guard !turns.isEmpty else { throw MemoryHistoryTestError.noTurn }
        return turns.removeFirst()
    }
}

private actor MemoryHistoryConversationStore: ConversationStore {
    private var conversations: [UUID: Conversation] = [:]

    func loadConversation(id: UUID) async throws -> Conversation? {
        conversations[id]
    }

    func saveConversation(_ conversation: Conversation) async throws {
        conversations[conversation.id] = conversation
    }
}

private enum MemoryHistoryTestError: Error {
    case noTurn
}
