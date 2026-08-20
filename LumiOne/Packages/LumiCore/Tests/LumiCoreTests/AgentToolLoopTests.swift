import Foundation
import XCTest
@testable import LumiCore

final class AgentToolLoopTests: XCTestCase {
    func testFileContentDoesNotReachModelBeforeExplicitApproval() async throws {
        let fixture = try AgentTextFixture(content: "TOP-SECRET-CONTENT")
        defer { fixture.cleanup() }

        let call = try ToolCall.encoding(
            name: "file.readText",
            version: "1",
            input: ReadTextFileInput(path: fixture.fileURL.path)
        )
        let model = ScriptedModel(turns: [
            .toolCall(call),
            .final("I read the authorized file.")
        ])
        let agent = try makeAgent(model: model)
        let conversationID = UUID()

        let first = try await agent.send("Read the selected file", conversationID: conversationID)
        guard case .permissionRequired(let pending) = first else {
            return XCTFail("Tool call must pause for explicit permission")
        }

        let beforeApproval = await model.capturedRequests()
        XCTAssertEqual(beforeApproval.count, 1)
        XCTAssertFalse(beforeApproval[0].messages.contains { $0.content.contains("TOP-SECRET-CONTENT") })
        XCTAssertEqual(pending.permission.capability, .readUserFile)

        let resumed = try await agent.approvePermission(
            pendingID: pending.id,
            duration: .once
        )
        guard case .completed(let response) = resumed else {
            return XCTFail("Approved tool call should resume to a final response")
        }

        XCTAssertEqual(response.assistantMessage.content, "I read the authorized file.")
        let afterApproval = await model.capturedRequests()
        XCTAssertEqual(afterApproval.count, 2)
        XCTAssertTrue(afterApproval[1].messages.contains {
            $0.role == .tool && $0.content.contains("TOP-SECRET-CONTENT")
        })
    }

    func testApprovalIsBoundToExactPendingOperationID() async throws {
        let fixture = try AgentTextFixture(content: "exact")
        defer { fixture.cleanup() }

        let call = try ToolCall.encoding(
            name: "file.readText",
            version: "1",
            input: ReadTextFileInput(path: fixture.fileURL.path)
        )
        let model = ScriptedModel(turns: [.toolCall(call), .final("done")])
        let agent = try makeAgent(model: model)

        let outcome = try await agent.send("Read it", conversationID: UUID())
        guard case .permissionRequired(let pending) = outcome else {
            return XCTFail("Expected pending permission")
        }

        do {
            _ = try await agent.approvePermission(pendingID: UUID(), duration: .once)
            XCTFail("Unknown pending ID must fail closed")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.description, "The pending permission request no longer exists.")
        }

        let resumed = try await agent.approvePermission(pendingID: pending.id, duration: .once)
        guard case .completed = resumed else {
            return XCTFail("Original pending operation must remain approvable")
        }
    }

    func testChatTextCannotApprovePendingAction() async throws {
        let fixture = try AgentTextFixture(content: "not-by-chat")
        defer { fixture.cleanup() }

        let call = try ToolCall.encoding(
            name: "file.readText",
            version: "1",
            input: ReadTextFileInput(path: fixture.fileURL.path)
        )
        let model = ScriptedModel(turns: [.toolCall(call), .final("done")])
        let agent = try makeAgent(model: model)
        let conversationID = UUID()

        let first = try await agent.send("Please read it", conversationID: conversationID)
        guard case .permissionRequired(let pending) = first else {
            return XCTFail("Expected pending permission")
        }

        do {
            _ = try await agent.send("yes, allow it", conversationID: conversationID)
            XCTFail("Chat prose must not act as permission")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(
                error.description,
                "This conversation is waiting for an explicit permission decision."
            )
        }

        let countBeforeExplicitApproval = await model.requestCount()
        XCTAssertEqual(countBeforeExplicitApproval, 1)
        _ = try await agent.approvePermission(pendingID: pending.id, duration: .once)
        let countAfterExplicitApproval = await model.requestCount()
        XCTAssertEqual(countAfterExplicitApproval, 2)
    }

    func testDenialIsPersistedAndModelCanContinue() async throws {
        let fixture = try AgentTextFixture(content: "must-not-leak")
        defer { fixture.cleanup() }

        let call = try ToolCall.encoding(
            name: "file.readText",
            version: "1",
            input: ReadTextFileInput(path: fixture.fileURL.path)
        )
        let model = ScriptedModel(turns: [
            .toolCall(call),
            .final("I will continue without the file.")
        ])
        let agent = try makeAgent(model: model)

        let first = try await agent.send("Try reading", conversationID: UUID())
        guard case .permissionRequired(let pending) = first else {
            return XCTFail("Expected pending permission")
        }

        let denied = try await agent.denyPermission(pendingID: pending.id)
        guard case .completed(let response) = denied else {
            return XCTFail("Model should be able to continue after denial")
        }
        XCTAssertEqual(response.assistantMessage.content, "I will continue without the file.")

        let requests = await model.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].messages.contains {
            $0.role == .tool && $0.content.contains("\"status\":\"denied\"")
        })
        XCTAssertFalse(requests[1].messages.contains { $0.content.contains("must-not-leak") })
    }

    func testToolLoopStopsAtHardStepLimit() async throws {
        let fixture = try AgentTextFixture(content: "loop")
        defer { fixture.cleanup() }

        let call = try ToolCall.encoding(
            name: "file.readText",
            version: "1",
            input: ReadTextFileInput(path: fixture.fileURL.path)
        )
        let model = RepeatingToolModel(call: call)
        let agent = try makeAgent(model: model, maxToolSteps: 2)

        let first = try await agent.send("Loop test", conversationID: UUID())
        guard case .permissionRequired(let pending) = first else {
            return XCTFail("Expected initial permission request")
        }

        do {
            _ = try await agent.approvePermission(pendingID: pending.id, duration: .session)
            XCTFail("Tool loop must stop at its configured hard limit")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.description, "Tool step limit exceeded (2).")
        }

        let count = await model.requestCount()
        XCTAssertEqual(count, 3)
    }

    func testToolFailureLeavesOriginalUserMessageDurable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiAgentFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("lumi.sqlite3")
        let conversationID = UUID()
        let store = try SQLiteConversationStore(url: databaseURL)
        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [AnyTool(FailingTool())])
        let tools = ToolRuntime(registry: registry, permissions: permissions)
        let call = try ToolCall.encoding(
            name: "test.fail",
            version: "1",
            input: FailingToolInput(resource: "fixture")
        )
        let model = ScriptedModel(turns: [.toolCall(call)])
        let agent = AgentRuntime(store: store, model: model, toolRuntime: tools)

        let first = try await agent.send("Persist before tool failure", conversationID: conversationID)
        guard case .permissionRequired(let pending) = first else {
            return XCTFail("Expected explicit permission before failing tool")
        }

        do {
            _ = try await agent.approvePermission(pendingID: pending.id, duration: .once)
            XCTFail("Failing tool should propagate its failure")
        } catch {
            // Expected.
        }

        let reopened = try SQLiteConversationStore(url: databaseURL)
        let restored = try await reopened.loadConversation(id: conversationID)
        XCTAssertEqual(restored?.messages.count, 1)
        XCTAssertEqual(restored?.messages.first?.role, .user)
        XCTAssertEqual(restored?.messages.first?.content, "Persist before tool failure")
    }

    private func makeAgent(
        model: any ModelProvider,
        maxToolSteps: Int = 8
    ) throws -> AgentRuntime {
        let store = MemoryConversationStore()
        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [AnyTool(ReadTextFileTool())])
        let tools = ToolRuntime(registry: registry, permissions: permissions)
        return AgentRuntime(
            store: store,
            model: model,
            toolRuntime: tools,
            maxToolSteps: maxToolSteps
        )
    }
}

private actor MemoryConversationStore: ConversationStore {
    private var conversations: [UUID: Conversation] = [:]

    func loadConversation(id: UUID) async throws -> Conversation? {
        conversations[id]
    }

    func saveConversation(_ conversation: Conversation) async throws {
        conversations[conversation.id] = conversation
    }
}

private actor ScriptedModel: ModelProvider {
    private var turns: [ModelTurn]
    private var requests: [ModelRequest] = []

    init(turns: [ModelTurn]) {
        self.turns = turns
    }

    func respond(to request: ModelRequest) async throws -> ModelTurn {
        requests.append(request)
        guard !turns.isEmpty else {
            throw ScriptedModelError.noMoreTurns
        }
        return turns.removeFirst()
    }

    func capturedRequests() -> [ModelRequest] {
        requests
    }

    func requestCount() -> Int {
        requests.count
    }
}

private actor RepeatingToolModel: ModelProvider {
    private let call: ToolCall
    private var count = 0

    init(call: ToolCall) {
        self.call = call
    }

    func respond(to request: ModelRequest) async throws -> ModelTurn {
        count += 1
        return .toolCall(call)
    }

    func requestCount() -> Int { count }
}

private enum ScriptedModelError: Error {
    case noMoreTurns
}

private struct FailingToolInput: Codable, Sendable {
    let resource: String
}

private struct FailingToolOutput: Codable, Sendable {
    let value: String
}

private struct FailingTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "test.fail",
        version: "1",
        summary: "A test tool that always fails after permission.",
        risk: .readOnly,
        capability: .readAppData
    )

    func resource(for input: FailingToolInput) throws -> ResourceScope {
        ResourceScope(kind: .appData, identifier: input.resource)
    }

    func execute(_ input: FailingToolInput) async throws -> FailingToolOutput {
        throw FailingToolError.expected
    }
}

private enum FailingToolError: Error {
    case expected
}

private final class AgentTextFixture {
    let directoryURL: URL
    let fileURL: URL

    init(content: String) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiAgentFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = directoryURL.appendingPathComponent("fixture.txt")
        try Data(content.utf8).write(to: fileURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
