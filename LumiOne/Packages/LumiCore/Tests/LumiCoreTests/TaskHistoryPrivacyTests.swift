import Foundation
import XCTest
@testable import LumiCore

final class TaskHistoryPrivacyTests: XCTestCase {
    func testApprovedTaskCreateKeepsInstructionInTaskStoreButRedactsDurableChatHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-task-history-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let taskStore = try SQLiteTaskStore(url: directory.appendingPathComponent("tasks.sqlite3"))
        let taskService = TaskService(store: taskStore)
        let secret = "TASK-HISTORY-PRIVATE-INSTRUCTION"
        let call = try ToolCall.encoding(
            name: "task.create",
            version: "1",
            input: CreateTaskInput(
                title: "Private durable task",
                instruction: secret,
                maxAttempts: 3
            ),
            providerCallID: "task-history-create-1"
        )
        let model = TaskHistoryModel(turns: [
            .toolCall(call),
            .final("The durable task was created."),
            .final("Follow-up complete.")
        ])
        let conversations = TaskHistoryConversationStore()
        let registry = try ToolRegistry(tools: [AnyTool(CreateTaskTool(service: taskService))])
        let runtime = AgentRuntime(
            store: conversations,
            model: model,
            toolRuntime: ToolRuntime(
                registry: registry,
                permissions: PermissionEngine()
            )
        )
        let conversationID = UUID()

        let first = try await runtime.send(
            "Create my private durable task.",
            conversationID: conversationID
        )
        guard case .permissionRequired(let pending) = first else {
            return XCTFail("Task creation must require approval")
        }

        let approved = try await runtime.approvePermission(
            pendingID: pending.id,
            duration: .session
        )
        guard case .completed = approved else {
            return XCTFail("Approved task create should complete")
        }

        let taskList = try await taskService.list()
        XCTAssertEqual(taskList.count, 1)
        XCTAssertEqual(taskList[0].instruction, secret)

        let durable = try await conversations.loadConversation(id: conversationID)
        let durableConversation = try XCTUnwrap(durable)
        let durableText = durableConversation.messages.map(\.content).joined(separator: "\n")
        XCTAssertFalse(durableText.contains(secret))
        XCTAssertTrue(durableText.contains("redacted:persistent-task-instruction"))

        let requestsAfterCreate = await model.requests()
        XCTAssertEqual(requestsAfterCreate.count, 2)
        let currentTurnToolText = requestsAfterCreate[1].messages
            .filter { $0.role == .tool }
            .map(\.content)
            .joined(separator: "\n")
        XCTAssertTrue(currentTurnToolText.contains(secret))

        _ = try await runtime.send(
            "What happened next?",
            conversationID: conversationID
        )
        let allRequests = await model.requests()
        XCTAssertEqual(allRequests.count, 3)
        let nextTurnHistory = allRequests[2].messages.map(\.content).joined(separator: "\n")
        XCTAssertFalse(nextTurnHistory.contains(secret))
        XCTAssertTrue(nextTurnHistory.contains("redacted:persistent-task-instruction"))
    }
}

private actor TaskHistoryConversationStore: ConversationStore {
    private var conversations: [UUID: Conversation] = [:]

    func loadConversation(id: UUID) async throws -> Conversation? {
        conversations[id]
    }

    func saveConversation(_ conversation: Conversation) async throws {
        conversations[conversation.id] = conversation
    }
}

private actor TaskHistoryModel: ModelProvider {
    private var turns: [ModelTurn]
    private var captured: [ModelRequest] = []

    init(turns: [ModelTurn]) {
        self.turns = turns
    }

    func respond(to request: ModelRequest) async throws -> ModelTurn {
        captured.append(request)
        guard !turns.isEmpty else { throw TaskHistoryTestError.noTurn }
        return turns.removeFirst()
    }

    func requests() -> [ModelRequest] {
        captured
    }
}

private enum TaskHistoryTestError: Error {
    case noTurn
}
