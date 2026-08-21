import XCTest
@testable import LumiCore

final class ConversationSessionTests: XCTestCase {
    func testSQLiteConversationLifecyclePreservesMetadataAndCountsMessages() async throws {
        let databaseURL = temporaryDatabase("conversation-lifecycle")
        let store = SQLiteConversationStore(databaseURL: databaseURL)
        let firstID = UUID()
        let secondID = UUID()
        let firstCreated = Date(timeIntervalSince1970: 1_000)
        let secondCreated = Date(timeIntervalSince1970: 2_000)

        _ = try await store.createConversation(id: firstID, title: "First", createdAt: firstCreated)
        _ = try await store.createConversation(id: secondID, title: "Second", createdAt: secondCreated)

        try await store.append(
            ChatMessage(role: .user, content: "hello", timestamp: Date(timeIntervalSince1970: 3_000)),
            conversationID: firstID
        )
        try await store.append(
            ChatMessage(role: .assistant, content: "hi", timestamp: Date(timeIntervalSince1970: 3_001)),
            conversationID: firstID
        )

        var conversations = try await store.listConversations(limit: 10)
        XCTAssertEqual(conversations.first?.id, firstID, "Latest message activity should move a conversation to the top.")
        XCTAssertEqual(conversations.first?.messageCount, 2)

        let renamed = try await store.renameConversation(id: firstID, title: "Renamed chat")
        XCTAssertEqual(renamed.title, "Renamed chat")
        XCTAssertEqual(renamed.messageCount, 2)

        try await store.clear(conversationID: firstID)
        let cleared = try await store.conversation(id: firstID)
        XCTAssertEqual(cleared?.title, "Renamed chat")
        XCTAssertEqual(cleared?.messageCount, 0)
        let clearedMessages = try await store.loadMessages(conversationID: firstID)
        XCTAssertTrue(clearedMessages.isEmpty)

        try await store.deleteConversation(id: firstID)
        let deleted = try await store.conversation(id: firstID)
        XCTAssertNil(deleted)
        conversations = try await store.listConversations(limit: 10)
        XCTAssertEqual(conversations.map(\.id), [secondID])
    }

    func testSharedRuntimeContainerKeepsConversationHistoryIsolatedAndLongTermMemoryGlobal() async throws {
        let conversationStore = InMemoryConversationStore()
        let memoryRuntime = MemoryRuntime(
            repository: SQLiteMemoryRepository(databaseURL: temporaryDatabase("conversation-shared-memory"))
        )
        let runtime = LumiRuntimeContainer(
            llm: SessionTestClient(),
            longTermMemory: memoryRuntime,
            knowledge: KnowledgeIndex(),
            conversationStore: conversationStore
        )
        let first = try await runtime.createConversation(title: "Alpha")
        let second = try await runtime.createConversation(title: "Beta")

        let firstEngine = runtime.makeEngine(conversationID: first.id)
        let secondEngine = runtime.makeEngine(conversationID: second.id)

        _ = await firstEngine.respond(to: "alpha-only", profile: "chat")
        _ = await secondEngine.respond(to: "beta-only", profile: "chat")

        let restoredFirst = try await runtime.makeEngine(conversationID: first.id).restoreConversation()
        let restoredSecond = try await runtime.makeEngine(conversationID: second.id).restoreConversation()

        XCTAssertEqual(restoredFirst.filter { $0.role == .user }.map(\.content), ["alpha-only"])
        XCTAssertEqual(restoredSecond.filter { $0.role == .user }.map(\.content), ["beta-only"])
        XCTAssertFalse(restoredFirst.contains(where: { $0.content.contains("beta-only") }))
        XCTAssertFalse(restoredSecond.contains(where: { $0.content.contains("alpha-only") }))

        let remembered = try await firstEngine.remember(
            "A global explicit memory",
            tags: ["shared"]
        )
        let memoriesFromSecond = try await secondEngine.storedMemories(limit: 20)
        XCTAssertTrue(memoriesFromSecond.contains(where: { $0.id == remembered.id }))
    }

    func testInitialConversationUsesMostRecentlyUpdatedSessionAndFreshStoreUsesLegacyID() async throws {
        let existingStore = InMemoryConversationStore()
        let runtime = LumiRuntimeContainer(
            llm: SessionTestClient(),
            knowledge: KnowledgeIndex(),
            conversationStore: existingStore
        )

        let older = try await runtime.createConversation(
            title: "Older",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let newer = try await runtime.createConversation(
            title: "Newer",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        try await existingStore.append(
            ChatMessage(role: .user, content: "recent activity", timestamp: Date(timeIntervalSince1970: 30)),
            conversationID: older.id
        )

        let initial = try await runtime.initialConversation()
        XCTAssertEqual(initial.id, older.id)
        XCTAssertNotEqual(initial.id, newer.id)

        let freshRuntime = LumiRuntimeContainer(
            llm: SessionTestClient(),
            knowledge: KnowledgeIndex(),
            conversationStore: InMemoryConversationStore()
        )
        let fresh = try await freshRuntime.initialConversation()
        XCTAssertEqual(fresh.id, LumiEngine.defaultConversationID)
        XCTAssertEqual(fresh.title, "New chat")
    }

    func testDeletingOneSQLiteConversationCascadesOnlyItsTranscript() async throws {
        let databaseURL = temporaryDatabase("conversation-delete-isolation")
        let store = SQLiteConversationStore(databaseURL: databaseURL)
        let first = try await store.createConversation(id: UUID(), title: "First", createdAt: Date())
        let second = try await store.createConversation(id: UUID(), title: "Second", createdAt: Date())

        try await store.append(ChatMessage(role: .user, content: "first payload"), conversationID: first.id)
        try await store.append(ChatMessage(role: .user, content: "second payload"), conversationID: second.id)
        try await store.deleteConversation(id: first.id)

        let firstMessages = try await store.loadMessages(conversationID: first.id)
        let secondMessages = try await store.loadMessages(conversationID: second.id)
        XCTAssertTrue(firstMessages.isEmpty)
        XCTAssertEqual(secondMessages.map(\.content), ["second payload"])
    }

    private func temporaryDatabase(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-\(prefix)-\(UUID().uuidString).sqlite3")
    }
}

private struct SessionTestClient: LLMClient {
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let latest = request.messages.last(where: { $0.role == .user })?.content ?? ""
        return ModelResponse(
            content: "reply:\(latest)",
            runtime: RuntimeMetadata(
                provider: .localFallback,
                model: "session-test",
                fallbackUsed: true,
                finishReason: .stop
            )
        )
    }
}
