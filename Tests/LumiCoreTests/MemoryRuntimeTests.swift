import XCTest
@testable import LumiCore

final class MemoryRuntimeTests: XCTestCase {
    func testMemoryPersistsAcrossRepositoryInstancesAndCanBeEditedDeleted() async throws {
        let databaseURL = temporaryDatabase("memory-persistence")
        let firstRuntime = MemoryRuntime(repository: SQLiteMemoryRepository(databaseURL: databaseURL))

        let created = try await firstRuntime.remember(
            "User prefers concise technical explanations.",
            kind: .semantic,
            importance: 0.8,
            isPinned: true,
            tags: ["preference", "style"]
        )

        let secondRuntime = MemoryRuntime(repository: SQLiteMemoryRepository(databaseURL: databaseURL))
        let restored = try await secondRuntime.all(limit: 20)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.id, created.id)
        XCTAssertTrue(restored.first?.isPinned == true)

        let updated = try await secondRuntime.update(
            id: created.id,
            content: "User prefers concise, highly technical explanations.",
            importance: 0.95
        )
        XCTAssertEqual(updated.importance, 0.95, accuracy: 0.0001)
        XCTAssertTrue(updated.content.contains("highly technical"))

        let hits = await secondRuntime.relevant(to: "technical style", limit: 5)
        XCTAssertEqual(hits.first?.record.id, created.id)

        try await secondRuntime.forget(id: created.id)
        let afterDelete = try await secondRuntime.all(limit: 20)
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testExplicitOnlyPolicyRejectsUnreviewedConversationDerivedMemory() async throws {
        let runtime = MemoryRuntime(
            repository: SQLiteMemoryRepository(databaseURL: temporaryDatabase("memory-policy")),
            writePolicy: .explicitOnly
        )

        do {
            _ = try await runtime.remember(
                "Inferred fact from conversation",
                source: MemorySource(kind: .conversationDerived)
            )
            XCTFail("Expected explicit-only memory policy to reject derived write.")
        } catch let error as MemoryError {
            guard case .policyDenied = error else {
                return XCTFail("Unexpected memory error: \(error)")
            }
        }
    }

    func testExpiredMemoryIsExcludedAndCanBePurged() async throws {
        let runtime = MemoryRuntime(repository: SQLiteMemoryRepository(databaseURL: temporaryDatabase("memory-expiry")))
        _ = try await runtime.remember(
            "Temporary trip detail",
            expiresAt: Date(timeIntervalSinceNow: -60),
            tags: ["trip"]
        )
        _ = try await runtime.remember(
            "Permanent motorcycle preference",
            tags: ["motorcycle"]
        )

        let active = try await runtime.all(limit: 20)
        XCTAssertEqual(active.count, 1)
        XCTAssertTrue(active.first?.content.contains("motorcycle") == true)

        let purged = try await runtime.purgeExpired()
        XCTAssertEqual(purged, 1)
    }

    func testContextBudgetPacksMemorySeparatelyFromKnowledge() {
        let manager = ContextBudgetManager(
            policy: ContextBudgetPolicy(
                contextWindow: 2_048,
                safetyMarginTokens: 128,
                knowledgeFraction: 0.25,
                memoryFraction: 0.25
            )
        )
        let profile = PromptProfile(name: "chat", system: "Answer clearly.", temperature: 0, maxTokens: 256)
        let current = ChatMessage(role: .user, content: "What should you remember about my editor?")
        let memory = MemoryHit(
            record: MemoryRecord(
                kind: .semantic,
                content: "User prefers Vim keybindings.",
                source: .explicitUser,
                importance: 0.9,
                tags: ["editor"]
            ),
            score: 1
        )
        let evidence = KnowledgeHit(
            document: KnowledgeDocument(id: "doc", title: "Manual", text: "Vim supports modal editing."),
            score: 1
        )

        let pack = manager.pack(
            profile: profile,
            history: [current],
            knowledge: [evidence],
            memories: [memory]
        )

        XCTAssertEqual(pack.memories.count, 1)
        XCTAssertEqual(pack.knowledge.count, 1)
        XCTAssertGreaterThan(pack.report.memoryTokens, 0)
        XCTAssertGreaterThan(pack.report.knowledgeTokens, 0)
        XCTAssertTrue(pack.systemPrompt.contains("[M1]"))
        XCTAssertTrue(pack.systemPrompt.contains("[S1]"))
        XCTAssertTrue(pack.systemPrompt.contains("must not be presented as source citations"))
    }

    func testEngineUsesExplicitMemoryAndClearConversationDoesNotDeleteIt() async throws {
        let databaseURL = temporaryDatabase("memory-engine")
        let memoryRuntime = MemoryRuntime(repository: SQLiteMemoryRepository(databaseURL: databaseURL))
        let recorder = MemoryRequestRecorder()
        let engine = LumiEngine(
            llm: MemoryRecordingClient(recorder: recorder),
            longTermMemory: memoryRuntime
        )

        let saved = try await engine.remember(
            "User prefers Hungarian for translation output.",
            tags: ["language", "translation"]
        )
        let reply = await engine.respond(to: "Which language should translation use?", profile: "chat")

        XCTAssertEqual(reply.memories.first?.record.id, saved.id)
        XCTAssertEqual(reply.contextBudget.selectedMemoryCount, 1)
        let systemPrompt = await recorder.lastSystemPrompt()
        XCTAssertTrue(systemPrompt?.contains("Hungarian") == true)
        XCTAssertTrue(systemPrompt?.contains("[M1]") == true)

        await engine.clearConversation()
        let stored = try await engine.storedMemories(limit: 20)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, saved.id)
    }

    private func temporaryDatabase(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-\(prefix)-\(UUID().uuidString).sqlite3")
    }
}

private actor MemoryRequestRecorder {
    private var systemPrompt: String?

    func record(_ request: ModelRequest) {
        systemPrompt = request.systemPrompt
    }

    func lastSystemPrompt() -> String? {
        systemPrompt
    }
}

private struct MemoryRecordingClient: LLMClient {
    let recorder: MemoryRequestRecorder

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        await recorder.record(request)
        return response
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await recorder.record(request)
                continuation.yield(.token("OK"))
                continuation.yield(.completed(response))
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private var response: ModelResponse {
        ModelResponse(
            content: "OK",
            runtime: RuntimeMetadata(
                provider: .localFallback,
                model: "memory-test",
                fallbackUsed: true,
                finishReason: .stop
            )
        )
    }
}
