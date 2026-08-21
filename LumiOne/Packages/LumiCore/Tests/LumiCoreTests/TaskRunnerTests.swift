import Foundation
import XCTest
@testable import LumiCore

final class TaskRunnerTests: XCTestCase {
    func testGolden007TaskCompletesThroughExistingAgentRuntime() async throws {
        let fixture = try TaskRunnerFixture(turns: [.final("Task completed deterministically.")])
        defer { fixture.cleanup() }
        let ready = try await fixture.makeReadyTask(title: "Complete me")

        let outcome = try await fixture.runner.start(
            taskID: ready.id,
            expectedRevision: ready.revision
        )
        guard case .completed(let task, let response) = outcome else {
            return XCTFail("Expected completed task")
        }
        XCTAssertEqual(task.state, .succeeded)
        XCTAssertEqual(task.attemptCount, 1)
        XCTAssertEqual(task.resultSummary, "Task completed deterministically.")
        XCTAssertEqual(response.assistantMessage.content, "Task completed deterministically.")

        let active = try await fixture.runner.activeTaskID()
        XCTAssertNil(active)
        let events = try await fixture.service.events(taskID: ready.id)
        XCTAssertEqual(events.map(\.toState), [.draft, .ready, .running, .succeeded])
        XCTAssertEqual(events.map(\.actor), [.user, .user, .runner, .runner])
    }

    func testGolden007ProtectedToolPausesTaskThenApprovalCompletesWithoutNewAttempt() async throws {
        let call = try ToolCall.encoding(
            name: "runner.protected",
            version: "1",
            input: RunnerProtectedInput(action: "read-protected-resource"),
            providerCallID: "task-runner-protected-1"
        )
        let fixture = try TaskRunnerFixture(
            turns: [
                .toolCall(call),
                .final("Protected work completed.")
            ],
            includeProtectedTool: true
        )
        defer { fixture.cleanup() }
        let ready = try await fixture.makeReadyTask(title: "Protected task")

        let first = try await fixture.runner.start(
            taskID: ready.id,
            expectedRevision: ready.revision
        )
        guard case .permissionRequired(let waiting, let approval) = first else {
            return XCTFail("Protected tool must pause the durable task")
        }
        XCTAssertEqual(waiting.state, .waitingForPermission)
        XCTAssertEqual(waiting.attemptCount, 1)
        XCTAssertEqual(approval.permission.capability, .externalAction)
        XCTAssertEqual(
            approval.permission.resource,
            ResourceScope(kind: .externalService, identifier: "runner-test")
        )

        let second = try await fixture.runner.approvePermission(
            taskID: waiting.id,
            pendingID: approval.id,
            duration: .once
        )
        guard case .completed(let completed, let response) = second else {
            return XCTFail("Approved protected flow should complete")
        }
        XCTAssertEqual(completed.state, .succeeded)
        XCTAssertEqual(completed.attemptCount, 1)
        XCTAssertEqual(response.assistantMessage.content, "Protected work completed.")

        let events = try await fixture.service.events(taskID: ready.id)
        XCTAssertEqual(
            events.map(\.toState),
            [.draft, .ready, .running, .waitingForPermission, .running, .succeeded]
        )
        XCTAssertEqual(events[3].actor, .runner)
        XCTAssertEqual(events[4].actor, .runner)
    }

    func testPermissionDenialBecomesExplicitFailedTaskWithoutAutoRetry() async throws {
        let call = try ToolCall.encoding(
            name: "runner.protected",
            version: "1",
            input: RunnerProtectedInput(action: "protected-write"),
            providerCallID: "task-runner-denied-1"
        )
        let fixture = try TaskRunnerFixture(
            turns: [
                .toolCall(call),
                .final("I could not continue without that permission.")
            ],
            includeProtectedTool: true
        )
        defer { fixture.cleanup() }
        let ready = try await fixture.makeReadyTask(title: "Denied task")

        let first = try await fixture.runner.start(
            taskID: ready.id,
            expectedRevision: ready.revision
        )
        guard case .permissionRequired(let waiting, let approval) = first else {
            return XCTFail("Expected permission pause")
        }

        let denied = try await fixture.runner.denyPermission(
            taskID: waiting.id,
            pendingID: approval.id
        )
        guard case .failed(let failed, let message) = denied else {
            return XCTFail("Denial must produce explicit failed state")
        }
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.attemptCount, 1)
        XCTAssertTrue(message.contains("permission denied"))
        XCTAssertTrue(failed.lastError?.contains("permission denied") == true)

        let active = try await fixture.runner.activeTaskID()
        XCTAssertNil(active)
        let events = try await fixture.service.events(taskID: ready.id)
        XCTAssertEqual(events.last?.toState, .failed)
        XCTAssertEqual(events.last?.actor, .runner)
    }

    func testRunnerAllowsOnlyOneExplicitTaskAtATime() async throws {
        let call = try ToolCall.encoding(
            name: "runner.protected",
            version: "1",
            input: RunnerProtectedInput(action: "hold-runner"),
            providerCallID: "task-runner-busy-1"
        )
        let fixture = try TaskRunnerFixture(
            turns: [.toolCall(call)],
            includeProtectedTool: true
        )
        defer { fixture.cleanup() }
        let firstReady = try await fixture.makeReadyTask(title: "First")
        let secondReady = try await fixture.makeReadyTask(title: "Second")

        let first = try await fixture.runner.start(
            taskID: firstReady.id,
            expectedRevision: firstReady.revision
        )
        guard case .permissionRequired = first else {
            return XCTFail("First task should hold runner while awaiting permission")
        }

        do {
            _ = try await fixture.runner.start(
                taskID: secondReady.id,
                expectedRevision: secondReady.revision
            )
            XCTFail("Second task must not run in parallel")
        } catch let error as TaskRunnerError {
            XCTAssertEqual(
                error,
                .busy(
                    activeTaskID: firstReady.id,
                    requestedTaskID: secondReady.id
                )
            )
        }

        let secondCurrentValue = try await fixture.service.load(id: secondReady.id)
        let secondCurrent = try XCTUnwrap(secondCurrentValue)
        XCTAssertEqual(secondCurrent.state, .ready)
        XCTAssertEqual(secondCurrent.attemptCount, 0)
    }

    func testInterruptedTaskResumesOnlyExplicitlyAndConsumesNewAttempt() async throws {
        let fixture = try TaskRunnerFixture(turns: [.final("Recovered task completed.")])
        defer { fixture.cleanup() }
        let ready = try await fixture.makeReadyTask(title: "Interrupted")
        let running = try await fixture.service.transition(
            id: ready.id,
            to: .running,
            expectedRevision: ready.revision,
            actor: .runner,
            reason: "First run"
        )
        let interrupted = try await fixture.service.transition(
            id: running.id,
            to: .interrupted,
            expectedRevision: running.revision,
            actor: .recovery,
            reason: "Simulated process restart",
            lastError: "Simulated process restart"
        )
        XCTAssertEqual(interrupted.attemptCount, 1)

        let outcome = try await fixture.runner.resume(
            taskID: interrupted.id,
            expectedRevision: interrupted.revision
        )
        guard case .completed(let completed, _) = outcome else {
            return XCTFail("Explicit resume should complete")
        }
        XCTAssertEqual(completed.state, .succeeded)
        XCTAssertEqual(completed.attemptCount, 2)

        let events = try await fixture.service.events(taskID: ready.id)
        let tail = Array(events.suffix(3))
        XCTAssertEqual(tail.map(\.toState), [.ready, .running, .succeeded])
        XCTAssertEqual(tail.map(\.actor), [.user, .runner, .runner])
    }

    func testModelProseCannotCreatePersistentTaskWithoutTypedToolCall() async throws {
        let directory = try temporaryDirectory(prefix: "lumi-task-prose-security")
        defer { try? FileManager.default.removeItem(at: directory) }
        let taskStore = try SQLiteTaskStore(url: directory.appendingPathComponent("tasks.sqlite3"))
        let taskService = TaskService(store: taskStore)
        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [
            AnyTool(CreateTaskTool(service: taskService)),
            AnyTool(EditTaskTool(service: taskService)),
            AnyTool(CancelTaskTool(service: taskService))
        ])
        let runtime = AgentRuntime(
            store: RunnerConversationStore(),
            model: RunnerScriptedModel(turns: [.final("I created the task and will do it later.")]),
            toolRuntime: ToolRuntime(registry: registry, permissions: permissions)
        )

        let outcome = try await runtime.send(
            "Create a durable task for tomorrow.",
            conversationID: UUID()
        )
        guard case .completed(let response) = outcome else {
            return XCTFail("Prose-only model turn should complete normally")
        }
        XCTAssertEqual(response.assistantMessage.content, "I created the task and will do it later.")
        let tasks = try await taskService.list()
        XCTAssertTrue(tasks.isEmpty)
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class TaskRunnerFixture: @unchecked Sendable {
    let directory: URL
    let taskStore: SQLiteTaskStore
    let service: TaskService
    let model: RunnerScriptedModel
    let runtime: AgentRuntime
    let runner: TaskRunner

    init(turns: [ModelTurn], includeProtectedTool: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-task-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        taskStore = try SQLiteTaskStore(url: directory.appendingPathComponent("tasks.sqlite3"))
        service = TaskService(store: taskStore)
        model = RunnerScriptedModel(turns: turns)

        let toolRuntime: ToolRuntime?
        if includeProtectedTool {
            let registry = try ToolRegistry(tools: [AnyTool(RunnerProtectedTool())])
            toolRuntime = ToolRuntime(registry: registry, permissions: PermissionEngine())
        } else {
            toolRuntime = nil
        }
        runtime = AgentRuntime(
            store: RunnerConversationStore(),
            model: model,
            toolRuntime: toolRuntime
        )
        runner = TaskRunner(tasks: service, runtime: runtime)
    }

    func makeReadyTask(title: String) async throws -> TaskRecord {
        let draft = try await service.create(
            title: title,
            instruction: "Execute task \(title)",
            maxAttempts: 3,
            actor: .user
        )
        return try await service.transition(
            id: draft.id,
            to: .ready,
            expectedRevision: draft.revision,
            actor: .user,
            reason: "User marked task ready"
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor RunnerConversationStore: ConversationStore {
    private var conversations: [UUID: Conversation] = [:]

    func loadConversation(id: UUID) async throws -> Conversation? {
        conversations[id]
    }

    func saveConversation(_ conversation: Conversation) async throws {
        conversations[conversation.id] = conversation
    }
}

private actor RunnerScriptedModel: ModelProvider {
    private var turns: [ModelTurn]
    private var captured: [ModelRequest] = []

    init(turns: [ModelTurn]) {
        self.turns = turns
    }

    func respond(to request: ModelRequest) async throws -> ModelTurn {
        captured.append(request)
        guard !turns.isEmpty else { throw RunnerTestError.noModelTurn }
        return turns.removeFirst()
    }

    func requests() -> [ModelRequest] {
        captured
    }
}

private struct RunnerProtectedInput: Codable, Equatable, Sendable {
    let action: String
}

private struct RunnerProtectedOutput: Codable, Equatable, Sendable {
    let completed: Bool
}

private struct RunnerProtectedTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "runner.protected",
        version: "1",
        summary: "Perform one protected test operation.",
        risk: .externalAction,
        capability: .externalAction,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object(["type": .string("string")])
            ]),
            "required": .array([.string("action")]),
            "additionalProperties": .bool(false)
        ])
    )

    func resource(for input: RunnerProtectedInput) throws -> ResourceScope {
        ResourceScope(kind: .externalService, identifier: "runner-test")
    }

    func permissionRequest(for input: RunnerProtectedInput) throws -> PermissionRequest {
        PermissionRequest(
            capability: Self.descriptor.capability,
            resource: try resource(for: input),
            reason: Self.descriptor.summary,
            resourceDisplayName: "TaskRunner protected test resource",
            details: ["action": input.action]
        )
    }

    func execute(_ input: RunnerProtectedInput) async throws -> RunnerProtectedOutput {
        RunnerProtectedOutput(completed: true)
    }
}

private enum RunnerTestError: Error {
    case noModelTurn
}
