import Foundation
import XCTest
@testable import LumiCore

final class MemoryRuntimeSecurityTests: XCTestCase {
    func testModelProseAloneCannotCreatePersistentMemory() async throws {
        let fixture = try RuntimeMemoryFixture()
        defer { fixture.cleanup() }

        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [
            AnyTool(RememberMemoryTool(service: fixture.service)),
            AnyTool(ForgetMemoryTool(service: fixture.service))
        ])
        let tools = ToolRuntime(registry: registry, permissions: permissions)
        let model = CapturingFinalModel(responses: [
            "I will remember that your favorite color is blue."
        ])
        let conversations = RuntimeMemoryConversationStore()
        let runtime = AgentRuntime(
            store: conversations,
            model: model,
            toolRuntime: tools
        )

        let outcome = try await runtime.send(
            "My favorite color is blue. Remember this.",
            conversationID: UUID()
        )
        guard case .completed = outcome else {
            return XCTFail("A prose-only model turn should complete normally")
        }

        let requests = await model.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].availableTools.contains { $0.name == "memory.remember" })
        XCTAssertTrue(requests[0].availableTools.contains { $0.name == "memory.forget" })

        // Tool availability and model prose are not authorization. No typed
        // memory operation occurred, so the durable memory store must be empty.
        XCTAssertTrue(try await fixture.store.listActive().isEmpty)
        XCTAssertNil(try await fixture.service.load(key: "profile.favorite.color"))
    }

    func testForgottenMemoryIsAbsentFromTheNextRuntimeTurnContext() async throws {
        let fixture = try RuntimeMemoryFixture()
        defer { fixture.cleanup() }

        let created = try await fixture.service.remember(
            key: "profile.answer.style",
            kind: .preference,
            value: "concise technical answers",
            confidence: 1.0,
            provenance: MemoryProvenance(sourceKind: .manualUserEntry)
        )

        let contextProvider = MemoryModelContextProvider(
            retriever: LexicalMemoryRetriever(store: fixture.store)
        )
        let model = CapturingFinalModel(responses: [
            "First answer.",
            "Second answer."
        ])
        let conversations = RuntimeMemoryConversationStore()
        let runtime = AgentRuntime(
            store: conversations,
            model: model,
            contextProvider: contextProvider
        )
        let conversationID = UUID()
        let query = "concise technical answers"

        _ = try await runtime.send(query, conversationID: conversationID)
        let firstRequests = await model.requests()
        XCTAssertEqual(firstRequests.count, 1)
        XCTAssertEqual(
            firstRequests[0].contextSnapshot?.userMemory?.entries.first?.hit.key,
            "profile.answer.style"
        )
        XCTAssertEqual(
            firstRequests[0].contextSnapshot?.userMemory?.entries.first?.hit.value,
            "concise technical answers"
        )

        let forgotten = try await fixture.service.forget(
            key: created.record.key,
            expectedRevision: created.record.revision
        )
        XCTAssertEqual(forgotten?.id, created.record.id)
        XCTAssertNil(try await fixture.service.load(key: created.record.key))

        // A new send must build a fresh context snapshot. It may not reuse a
        // stale prior-turn memory snapshot after explicit forget.
        _ = try await runtime.send(query, conversationID: conversationID)
        let requests = await model.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[1].contextSnapshot?.userMemory)
    }
}

private final class RuntimeMemoryFixture: @unchecked Sendable {
    let directory: URL
    let store: SQLiteMemoryStore
    let service: MemoryService

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-memory-runtime-security-\(UUID().uuidString)")
        store = try SQLiteMemoryStore(
            url: directory.appendingPathComponent("memory.sqlite3")
        )
        service = MemoryService(store: store)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor RuntimeMemoryConversationStore: ConversationStore {
    private var conversations: [UUID: Conversation] = [:]

    func loadConversation(id: UUID) async throws -> Conversation? {
        conversations[id]
    }

    func saveConversation(_ conversation: Conversation) async throws {
        conversations[conversation.id] = conversation
    }
}

private actor CapturingFinalModel: ModelProvider {
    private var remainingResponses: [String]
    private var capturedRequests: [ModelRequest] = []

    init(responses: [String]) {
        remainingResponses = responses
    }

    func respond(to request: ModelRequest) async throws -> ModelTurn {
        capturedRequests.append(request)
        guard !remainingResponses.isEmpty else {
            throw RuntimeMemoryTestError.noResponse
        }
        return .final(remainingResponses.removeFirst())
    }

    func requests() -> [ModelRequest] {
        capturedRequests
    }
}

private enum RuntimeMemoryTestError: Error {
    case noResponse
}
