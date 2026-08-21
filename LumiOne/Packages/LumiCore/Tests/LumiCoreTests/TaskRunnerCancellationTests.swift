import Foundation
import XCTest
@testable import LumiCore

final class TaskRunnerCancellationTests: XCTestCase {
    func testCancellingWaitingTaskAbandonsPendingAgentContinuation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let taskStore = try SQLiteTaskStore(url: directory.appendingPathComponent("tasks.sqlite3"))
        let service = TaskService(store: taskStore)
        let call = try ToolCall.encoding(
            name: "cancel.protected",
            version: "1",
            input: CancelProtectedInput(value: "hold"),
            providerCallID: "cancel-pending-1"
        )
        let model = CancelScriptedModel(turns: [.toolCall(call)])
        let registry = try ToolRegistry(tools: [AnyTool(CancelProtectedTool())])
        let runtime = AgentRuntime(
            store: CancelConversationStore(),
            model: model,
            toolRuntime: ToolRuntime(
                registry: registry,
                permissions: PermissionEngine()
            )
        )
        let runner = TaskRunner(tasks: service, runtime: runtime)

        let draft = try await service.create(
            title: "Cancel pending",
            instruction: "Request protected work",
            maxAttempts: 3,
            actor: .user
        )
        let ready = try await service.transition(
            id: draft.id,
            to: .ready,
            expectedRevision: draft.revision,
            actor: .user
        )

        let started = try await runner.start(
            taskID: ready.id,
            expectedRevision: ready.revision
        )
        guard case .permissionRequired(let waiting, let approval) = started else {
            return XCTFail("Expected waiting permission state")
        }
        XCTAssertEqual(waiting.state, .waitingForPermission)

        let cancelled = try await runner.cancel(
            taskID: waiting.id,
            expectedRevision: waiting.revision,
            reason: "User cancelled while waiting"
        )
        XCTAssertEqual(cancelled.state, .cancelled)

        let active = try await runner.activeTaskID()
        XCTAssertNil(active)

        do {
            _ = try await runtime.approvePermission(
                pendingID: approval.id,
                duration: .once
            )
            XCTFail("Abandoned pending continuation must no longer be approvable")
        } catch let error as AgentRuntimeError {
            guard case .pendingPermissionNotFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let currentValue = try await service.load(id: ready.id)
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current.state, .cancelled)
        XCTAssertEqual(current.attemptCount, 1)
        let events = try await service.events(taskID: ready.id)
        XCTAssertEqual(events.last?.toState, .cancelled)
        XCTAssertEqual(events.last?.actor, .user)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-task-cancel-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor CancelConversationStore: ConversationStore {
    private var conversations: [UUID: Conversation] = [:]

    func loadConversation(id: UUID) async throws -> Conversation? {
        conversations[id]
    }

    func saveConversation(_ conversation: Conversation) async throws {
        conversations[conversation.id] = conversation
    }
}

private actor CancelScriptedModel: ModelProvider {
    private var turns: [ModelTurn]

    init(turns: [ModelTurn]) {
        self.turns = turns
    }

    func respond(to request: ModelRequest) async throws -> ModelTurn {
        guard !turns.isEmpty else { throw CancelTestError.noTurn }
        return turns.removeFirst()
    }
}

private struct CancelProtectedInput: Codable, Sendable {
    let value: String
}

private struct CancelProtectedOutput: Codable, Sendable {
    let ok: Bool
}

private struct CancelProtectedTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "cancel.protected",
        version: "1",
        summary: "Protected cancellation regression operation.",
        risk: .externalAction,
        capability: .externalAction,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object(["type": .string("string")])
            ]),
            "required": .array([.string("value")]),
            "additionalProperties": .bool(false)
        ])
    )

    func resource(for input: CancelProtectedInput) throws -> ResourceScope {
        ResourceScope(kind: .externalService, identifier: "cancel-test")
    }

    func permissionRequest(for input: CancelProtectedInput) throws -> PermissionRequest {
        PermissionRequest(
            capability: Self.descriptor.capability,
            resource: try resource(for: input),
            reason: Self.descriptor.summary,
            details: ["value": input.value]
        )
    }

    func execute(_ input: CancelProtectedInput) async throws -> CancelProtectedOutput {
        CancelProtectedOutput(ok: true)
    }
}

private enum CancelTestError: Error {
    case noTurn
}
