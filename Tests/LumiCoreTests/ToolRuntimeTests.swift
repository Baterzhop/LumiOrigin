import XCTest
@testable import LumiCore

final class ToolRuntimeTests: XCTestCase {
    func testReadOnlyWorkspaceToolsListAndReadInsideSandbox() async throws {
        let workspace = temporaryDirectory("workspace-success")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("notes.txt")
        try Data("Lumi tool sandbox".utf8).write(to: file)

        let sandbox = WorkspaceSandbox(rootURL: workspace)
        let runtime = ToolRuntime(
            registry: ToolRegistry(tools: [
                ListWorkspaceFilesTool(sandbox: sandbox),
                ReadWorkspaceTextFileTool(sandbox: sandbox)
            ])
        )

        let list = await runtime.execute(
            ToolCall(
                toolName: "workspace.list_files",
                arguments: ["path": .string("")],
                origin: .user
            )
        )
        XCTAssertEqual(list.status, .success)
        XCTAssertEqual(list.trust, .untrusted)
        guard case .array(let rows)? = list.output else {
            return XCTFail("Expected array output from list tool.")
        }
        XCTAssertEqual(rows.count, 1)

        let read = await runtime.execute(
            ToolCall(
                toolName: "workspace.read_text_file",
                arguments: ["path": .string("notes.txt")],
                origin: .user
            )
        )
        XCTAssertEqual(read.status, .success)
        guard case .object(let object)? = read.output,
              case .string(let content)? = object["content"] else {
            return XCTFail("Expected text content from read tool.")
        }
        XCTAssertEqual(content, "Lumi tool sandbox")
    }

    func testWorkspaceRejectsPathTraversalAndSymlinkEscape() async throws {
        let parent = temporaryDirectory("workspace-escape")
        let workspace = parent.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let outside = parent.appendingPathComponent("secret.txt")
        try Data("outside".utf8).write(to: outside)

        let sandbox = WorkspaceSandbox(rootURL: workspace)
        let runtime = ToolRuntime(
            registry: ToolRegistry(tools: [ReadWorkspaceTextFileTool(sandbox: sandbox)])
        )

        let traversal = await runtime.execute(
            ToolCall(
                toolName: "workspace.read_text_file",
                arguments: ["path": .string("../secret.txt")],
                origin: .user
            )
        )
        XCTAssertEqual(traversal.status, .failed)
        XCTAssertTrue(traversal.error?.contains("sandbox") == true || traversal.error?.contains("escapes") == true)

        let link = workspace.appendingPathComponent("linked-secret.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let symlinkEscape = await runtime.execute(
            ToolCall(
                toolName: "workspace.read_text_file",
                arguments: ["path": .string("linked-secret.txt")],
                origin: .user
            )
        )
        XCTAssertEqual(symlinkEscape.status, .failed)
        XCTAssertTrue(symlinkEscape.error?.contains("sandbox") == true || symlinkEscape.error?.contains("escapes") == true)
    }

    func testWriteAndDestructiveToolsAreDeniedBeforeExecution() async {
        let recorder = ExecutionRecorder()
        let runtime = ToolRuntime(
            registry: ToolRegistry(tools: [MockWriteTool(recorder: recorder)]),
            policy: ToolPermissionPolicy(writeToolsEnabled: false)
        )

        let result = await runtime.execute(
            ToolCall(toolName: "test.write", origin: .agent)
        )

        XCTAssertEqual(result.status, .denied)
        XCTAssertFalse(await recorder.wasExecuted())
    }

    func testReadOnlyMediumRiskToolRequiresMatchingConfirmation() async {
        let runtime = ToolRuntime(
            registry: ToolRegistry(tools: [ConfirmedReadTool()])
        )
        let call = ToolCall(toolName: "test.confirmed_read", origin: .agent)

        let first = await runtime.execute(call)
        XCTAssertEqual(first.status, .confirmationRequired)

        let wrongConfirmation = ToolConfirmation(callID: UUID(), approved: true)
        let wrong = await runtime.execute(call, confirmation: wrongConfirmation)
        XCTAssertEqual(wrong.status, .denied)

        let approved = await runtime.execute(
            call,
            confirmation: ToolConfirmation(callID: call.id, approved: true)
        )
        XCTAssertEqual(approved.status, .success)
    }

    func testSchemaValidationRejectsMissingUnknownAndWrongTypeArguments() async {
        let workspace = temporaryDirectory("workspace-schema")
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let runtime = ToolRuntime(
            registry: ToolRegistry(tools: [ReadWorkspaceTextFileTool(sandbox: WorkspaceSandbox(rootURL: workspace))])
        )

        let missing = await runtime.execute(
            ToolCall(toolName: "workspace.read_text_file", origin: .user)
        )
        XCTAssertEqual(missing.status, .failed)
        XCTAssertTrue(missing.error?.contains("Missing required field") == true)

        let unknown = await runtime.execute(
            ToolCall(
                toolName: "workspace.read_text_file",
                arguments: ["path": .string("a.txt"), "extra": .string("x")],
                origin: .user
            )
        )
        XCTAssertEqual(unknown.status, .failed)
        XCTAssertTrue(unknown.error?.contains("Unknown field") == true)

        let wrongType = await runtime.execute(
            ToolCall(
                toolName: "workspace.read_text_file",
                arguments: ["path": .integer(42)],
                origin: .user
            )
        )
        XCTAssertEqual(wrongType.status, .failed)
        XCTAssertTrue(wrongType.error?.contains("must have type") == true)
    }

    func testAuditPersistsAcrossStoreInstances() async throws {
        let databaseURL = temporaryDirectory("tool-audit")
            .appendingPathComponent("audit.sqlite3")
        let firstStore = SQLiteToolAuditStore(databaseURL: databaseURL)
        let firstRuntime = ToolRuntime(
            registry: ToolRegistry(tools: [ConfirmedReadTool()]),
            auditStore: firstStore
        )
        let call = ToolCall(toolName: "test.confirmed_read", origin: .user)
        _ = await firstRuntime.execute(call)

        let secondStore = SQLiteToolAuditStore(databaseURL: databaseURL)
        let restored = try await secondStore.recent(limit: 10)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.call.id, call.id)
        XCTAssertEqual(restored.first?.resultStatus, .confirmationRequired)
    }

    func testEngineExposesToolsButChatDoesNotExecuteThemAutomatically() async {
        let recorder = ExecutionRecorder()
        let toolRuntime = ToolRuntime(
            registry: ToolRegistry(tools: [MockReadTool(recorder: recorder)])
        )
        let promptRecorder = ToolPromptRecorder()
        let engine = LumiEngine(
            llm: ToolBoundaryRecordingClient(recorder: promptRecorder),
            toolRuntime: toolRuntime
        )

        let tools = await engine.availableTools()
        XCTAssertEqual(tools.map(\.name), ["test.read"])

        let reply = await engine.respond(to: "run the script with a tool")
        XCTAssertTrue(reply.classification.capabilities.contains(.tools))
        XCTAssertFalse(await recorder.wasExecuted())
        let prompt = await promptRecorder.lastSystemPrompt()
        XCTAssertTrue(prompt?.contains("cannot invoke tools automatically") == true)
    }

    private func temporaryDirectory(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}

private actor ExecutionRecorder {
    private var executed = false

    func markExecuted() {
        executed = true
    }

    func wasExecuted() -> Bool {
        executed
    }
}

private struct MockWriteTool: LumiTool {
    let recorder: ExecutionRecorder

    var definition: ToolDefinition {
        ToolDefinition(
            name: "test.write",
            description: "Test write tool",
            outputDescription: "Test output",
            access: .write,
            risk: .medium
        )
    }

    func execute(arguments: [String: ToolValue]) async throws -> ToolValue {
        await recorder.markExecuted()
        return .string("executed")
    }
}

private struct ConfirmedReadTool: LumiTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "test.confirmed_read",
            description: "Test read tool requiring confirmation",
            outputDescription: "Test output",
            access: .readOnly,
            risk: .medium,
            requiresConfirmation: true
        )
    }

    func execute(arguments: [String: ToolValue]) async throws -> ToolValue {
        .string("approved")
    }
}

private struct MockReadTool: LumiTool {
    let recorder: ExecutionRecorder

    var definition: ToolDefinition {
        ToolDefinition(
            name: "test.read",
            description: "Test read tool",
            outputDescription: "Test output",
            access: .readOnly,
            risk: .low
        )
    }

    func execute(arguments: [String: ToolValue]) async throws -> ToolValue {
        await recorder.markExecuted()
        return .string("read")
    }
}

private actor ToolPromptRecorder {
    private var systemPrompt: String?

    func record(_ request: ModelRequest) {
        systemPrompt = request.systemPrompt
    }

    func lastSystemPrompt() -> String? {
        systemPrompt
    }
}

private struct ToolBoundaryRecordingClient: LLMClient {
    let recorder: ToolPromptRecorder

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        await recorder.record(request)
        return response
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await recorder.record(request)
                continuation.yield(.completed(response))
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private var response: ModelResponse {
        ModelResponse(
            content: "No tool was executed.",
            runtime: RuntimeMetadata(
                provider: .localFallback,
                model: "tool-boundary-test",
                fallbackUsed: true,
                finishReason: .stop
            )
        )
    }
}
