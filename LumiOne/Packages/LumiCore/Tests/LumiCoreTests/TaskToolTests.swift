import Foundation
import XCTest
@testable import LumiCore

final class TaskToolTests: XCTestCase {
    func testCreateRequiresExactApprovalAndSessionGrantIsDowngradedToOnce() async throws {
        let fixture = try TaskToolFixture()
        defer { fixture.cleanup() }

        let call = try ToolCall.encoding(
            name: "task.create",
            version: "1",
            input: CreateTaskInput(
                title: "Prepare report",
                instruction: "Read the selected report source and prepare a summary.",
                maxAttempts: 3
            )
        )

        let first = try await fixture.runtime.execute(call)
        guard case .permissionRequired(let request) = first else {
            return XCTFail("Persistent task creation must pause for permission")
        }
        XCTAssertEqual(request.capability, .writeUserTask)
        XCTAssertEqual(request.resource, .newUserTask)
        XCTAssertEqual(request.details["operation"], "create")
        XCTAssertEqual(request.details["title"], "Prepare report")
        XCTAssertEqual(
            request.details["instruction"],
            "Read the selected report source and prepare a summary."
        )

        let before = try await fixture.service.list()
        XCTAssertTrue(before.isEmpty)

        let grant = await fixture.runtime.grant(request, duration: .session)
        XCTAssertEqual(grant.duration, .once)

        let second = try await fixture.runtime.execute(call)
        guard case .success(let success) = second else {
            return XCTFail("Approved create should execute")
        }
        let output = try decode(TaskMutationOutput.self, from: success.data)
        XCTAssertEqual(output.title, "Prepare report")
        XCTAssertEqual(output.state, .draft)
        XCTAssertEqual(output.revision, 1)

        let tasks = try await fixture.service.list()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].id.description, output.taskID)
        XCTAssertEqual(tasks[0].instruction, "Read the selected report source and prepare a summary.")

        let third = try await fixture.runtime.execute(call)
        guard case .permissionRequired = third else {
            return XCTFail("Each persistent task creation must require a new approval")
        }
    }

    func testChangedCreateInstructionCannotReuseApprovalForSameNewTaskScope() async throws {
        let fixture = try TaskToolFixture()
        defer { fixture.cleanup() }

        let approved = try ToolCall.encoding(
            name: "task.create",
            version: "1",
            input: CreateTaskInput(
                title: "Task",
                instruction: "Original exact instruction",
                maxAttempts: 2
            )
        )
        let changed = try ToolCall.encoding(
            name: "task.create",
            version: "1",
            input: CreateTaskInput(
                title: "Task",
                instruction: "Changed instruction",
                maxAttempts: 2
            )
        )

        let first = try await fixture.runtime.execute(approved)
        guard case .permissionRequired(let approvedRequest) = first else {
            return XCTFail("Expected create approval")
        }
        _ = await fixture.runtime.grant(approvedRequest, duration: .once)

        let changedOutcome = try await fixture.runtime.execute(changed)
        guard case .permissionRequired(let changedRequest) = changedOutcome else {
            return XCTFail("Changed task instruction must require a new approval")
        }
        XCTAssertEqual(changedRequest.resource, approvedRequest.resource)
        XCTAssertNotEqual(changedRequest.details, approvedRequest.details)
        XCTAssertEqual(changedRequest.details["instruction"], "Changed instruction")

        let beforeOriginal = try await fixture.service.list()
        XCTAssertTrue(beforeOriginal.isEmpty)

        let originalOutcome = try await fixture.runtime.execute(approved)
        guard case .success = originalOutcome else {
            return XCTFail("Original exact operation should still match its grant")
        }
        let persisted = try await fixture.service.list()
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].instruction, "Original exact instruction")
    }

    func testEditApprovalIsBoundToExactTaskRevisionAndInstruction() async throws {
        let fixture = try TaskToolFixture()
        defer { fixture.cleanup() }

        let original = try await fixture.service.create(
            title: "Original",
            instruction: "Original instruction",
            maxAttempts: 3,
            actor: .user
        )
        let approvedInput = EditTaskInput(
            taskID: original.id.description,
            title: "Edited",
            instruction: "Approved instruction",
            maxAttempts: 3,
            expectedRevision: original.revision
        )
        let changedInput = EditTaskInput(
            taskID: original.id.description,
            title: "Edited",
            instruction: "Different instruction",
            maxAttempts: 3,
            expectedRevision: original.revision
        )
        let approvedCall = try ToolCall.encoding(name: "task.edit", version: "1", input: approvedInput)
        let changedCall = try ToolCall.encoding(name: "task.edit", version: "1", input: changedInput)

        let first = try await fixture.runtime.execute(approvedCall)
        guard case .permissionRequired(let request) = first else {
            return XCTFail("Edit should require permission")
        }
        XCTAssertEqual(request.resource, .userTask(original.id))
        XCTAssertEqual(request.details["expectedRevision"], "1")
        XCTAssertEqual(request.details["instruction"], "Approved instruction")
        _ = await fixture.runtime.grant(request, duration: .once)

        let changed = try await fixture.runtime.execute(changedCall)
        guard case .permissionRequired(let changedRequest) = changed else {
            return XCTFail("Changed edit must not reuse exact approval")
        }
        XCTAssertNotEqual(changedRequest.details, request.details)

        let unchangedValue = try await fixture.service.load(id: original.id)
        let unchanged = try XCTUnwrap(unchangedValue)
        XCTAssertEqual(unchanged.instruction, "Original instruction")

        let approvedResult = try await fixture.runtime.execute(approvedCall)
        guard case .success = approvedResult else {
            return XCTFail("Original approved edit should execute")
        }
        let editedValue = try await fixture.service.load(id: original.id)
        let edited = try XCTUnwrap(editedValue)
        XCTAssertEqual(edited.instruction, "Approved instruction")
        XCTAssertEqual(edited.revision, 2)
    }

    func testApprovedEditFailsIfTaskRevisionChangesBeforeExecution() async throws {
        let fixture = try TaskToolFixture()
        defer { fixture.cleanup() }

        let original = try await fixture.service.create(
            title: "Original",
            instruction: "Original instruction",
            maxAttempts: 3,
            actor: .user
        )
        let call = try ToolCall.encoding(
            name: "task.edit",
            version: "1",
            input: EditTaskInput(
                taskID: original.id.description,
                title: "Model edit",
                instruction: "Model-approved instruction",
                maxAttempts: 3,
                expectedRevision: original.revision
            )
        )

        let pending = try await fixture.runtime.execute(call)
        guard case .permissionRequired(let request) = pending else {
            return XCTFail("Expected edit approval")
        }

        _ = try await fixture.service.edit(
            id: original.id,
            title: "User edit",
            instruction: "User changed it first",
            maxAttempts: 3,
            nextEligibleAt: nil,
            expectedRevision: original.revision,
            actor: .user,
            reason: "Concurrent user edit"
        )
        _ = await fixture.runtime.grant(request, duration: .once)

        do {
            _ = try await fixture.runtime.execute(call)
            XCTFail("Stale approved task edit must fail")
        } catch let error as TaskStoreError {
            XCTAssertEqual(
                error,
                .revisionConflict(
                    taskID: original.id,
                    expected: 1,
                    actual: 2
                )
            )
        }

        let currentValue = try await fixture.service.load(id: original.id)
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current.title, "User edit")
        XCTAssertEqual(current.instruction, "User changed it first")
    }

    func testCancelIsExactOneOperationAndLeavesDurableAuditState() async throws {
        let fixture = try TaskToolFixture()
        defer { fixture.cleanup() }

        let original = try await fixture.service.create(
            title: "Cancel me",
            instruction: "Do not delete the record",
            maxAttempts: 3,
            actor: .user
        )
        let call = try ToolCall.encoding(
            name: "task.cancel",
            version: "1",
            input: CancelTaskInput(
                taskID: original.id.description,
                expectedRevision: original.revision,
                reason: "No longer needed"
            )
        )

        let first = try await fixture.runtime.execute(call)
        guard case .permissionRequired(let request) = first else {
            return XCTFail("Cancel should require permission")
        }
        XCTAssertEqual(request.capability, .writeUserTask)
        XCTAssertEqual(request.resource, .userTask(original.id))
        XCTAssertEqual(request.details["operation"], "cancel")
        let grant = await fixture.runtime.grant(request, duration: .session)
        XCTAssertEqual(grant.duration, .once)

        let executed = try await fixture.runtime.execute(call)
        guard case .success = executed else {
            return XCTFail("Approved cancel should execute")
        }
        let currentValue = try await fixture.service.load(id: original.id)
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current.state, .cancelled)
        XCTAssertEqual(current.revision, 2)

        let events = try await fixture.service.events(taskID: original.id)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.actor, .approvedModel)
        XCTAssertEqual(events.last?.toState, .cancelled)
        XCTAssertEqual(events.last?.reason, "No longer needed")
    }

    func testTaskInstructionIsRedactedFromDurableToolArguments() async throws {
        let fixture = try TaskToolFixture()
        defer { fixture.cleanup() }

        let secret = "TASK-INSTRUCTION-SECRET"
        let tool = CreateTaskTool(service: fixture.service)
        let history = try tool.historyArguments(
            for: CreateTaskInput(
                title: "Private task",
                instruction: secret,
                maxAttempts: 3
            )
        )
        let encoded = try JSONEncoder().encode(history)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains("redacted:persistent-task-instruction"))
    }

    func testTaskToolSchemaDoesNotExposeMutationActorOrPermissionAuthority() throws {
        for descriptor in [
            CreateTaskTool.descriptor,
            EditTaskTool.descriptor,
            CancelTaskTool.descriptor
        ] {
            guard case .object(let schema) = descriptor.inputSchema,
                  case .object(let properties)? = schema["properties"] else {
                return XCTFail("Expected object input schema")
            }
            XCTAssertNil(properties["actor"])
            XCTAssertNil(properties["permission"])
            XCTAssertNil(properties["grant"])
            XCTAssertNil(properties["capability"])
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }
}

private final class TaskToolFixture: @unchecked Sendable {
    let directory: URL
    let store: SQLiteTaskStore
    let service: TaskService
    let runtime: ToolRuntime

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-task-tool-tests-\(UUID().uuidString)")
        let databaseURL = directory.appendingPathComponent("tasks.sqlite3")
        store = try SQLiteTaskStore(url: databaseURL)
        service = TaskService(store: store)
        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [
            AnyTool(CreateTaskTool(service: service)),
            AnyTool(EditTaskTool(service: service)),
            AnyTool(CancelTaskTool(service: service))
        ])
        runtime = ToolRuntime(registry: registry, permissions: permissions)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
