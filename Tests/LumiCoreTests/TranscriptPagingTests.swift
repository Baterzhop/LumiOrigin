import XCTest
@testable import LumiCore

final class TranscriptPagingTests: XCTestCase {
    func testSQLitePagingReturnsNewestPageThenOlderPagesWithoutDuplicates() async throws {
        let store = SQLiteConversationStore(databaseURL: temporaryDatabase("paging"))
        let conversation = try await store.createConversation(
            id: UUID(),
            title: "Paged",
            createdAt: Date(timeIntervalSince1970: 0)
        )

        for index in 0..<25 {
            try await store.append(
                ChatMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: "message-\(index)",
                    timestamp: Date(timeIntervalSince1970: Double(index))
                ),
                conversationID: conversation.id
            )
        }

        let newest = try await store.loadTranscriptPage(
            conversationID: conversation.id,
            before: nil,
            limit: 10
        )
        XCTAssertEqual(newest.messages.map(\.content), (15..<25).map { "message-\($0)" })
        XCTAssertTrue(newest.hasOlder)
        XCTAssertNotNil(newest.olderCursor)

        let middle = try await store.loadTranscriptPage(
            conversationID: conversation.id,
            before: newest.olderCursor,
            limit: 10
        )
        XCTAssertEqual(middle.messages.map(\.content), (5..<15).map { "message-\($0)" })
        XCTAssertTrue(middle.hasOlder)

        let oldest = try await store.loadTranscriptPage(
            conversationID: conversation.id,
            before: middle.olderCursor,
            limit: 10
        )
        XCTAssertEqual(oldest.messages.map(\.content), (0..<5).map { "message-\($0)" })
        XCTAssertFalse(oldest.hasOlder)
        XCTAssertNil(oldest.olderCursor)

        let ids = newest.messages + middle.messages + oldest.messages
        XCTAssertEqual(Set(ids.map(\.id)).count, 25)
    }

    func testSQLiteCursorRemainsStableWhenNewMessagesArriveAtTranscriptEnd() async throws {
        let store = SQLiteConversationStore(databaseURL: temporaryDatabase("paging-concurrent-append"))
        let conversation = try await store.createConversation(id: UUID(), title: "Stable", createdAt: Date())

        for index in 0..<12 {
            try await store.append(
                ChatMessage(
                    role: .user,
                    content: "before-\(index)",
                    timestamp: Date(timeIntervalSince1970: Double(index))
                ),
                conversationID: conversation.id
            )
        }

        let newest = try await store.loadTranscriptPage(
            conversationID: conversation.id,
            before: nil,
            limit: 5
        )
        XCTAssertEqual(newest.messages.map(\.content), (7..<12).map { "before-\($0)" })

        try await store.append(
            ChatMessage(
                role: .assistant,
                content: "arrived-later",
                timestamp: Date(timeIntervalSince1970: 100)
            ),
            conversationID: conversation.id
        )

        let older = try await store.loadTranscriptPage(
            conversationID: conversation.id,
            before: newest.olderCursor,
            limit: 5
        )
        XCTAssertEqual(older.messages.map(\.content), (2..<7).map { "before-\($0)" })
        XCTAssertFalse(older.messages.contains(where: { $0.content == "arrived-later" }))
    }

    func testSQLitePagingHandlesIdenticalTimestampsWithoutLossOrDuplication() async throws {
        let store = SQLiteConversationStore(databaseURL: temporaryDatabase("paging-same-time"))
        let conversation = try await store.createConversation(id: UUID(), title: "Same time", createdAt: Date())
        let timestamp = Date(timeIntervalSince1970: 42)

        for index in 0..<9 {
            try await store.append(
                ChatMessage(role: .user, content: "same-\(index)", timestamp: timestamp),
                conversationID: conversation.id
            )
        }

        var cursor: ConversationTranscriptCursor?
        var collected: [ChatMessage] = []
        repeat {
            let page = try await store.loadTranscriptPage(
                conversationID: conversation.id,
                before: cursor,
                limit: 4
            )
            collected = page.messages + collected
            cursor = page.olderCursor
            if !page.hasOlder { break }
        } while true

        XCTAssertEqual(collected.count, 9)
        XCTAssertEqual(Set(collected.map(\.id)).count, 9)
        XCTAssertEqual(Set(collected.map(\.content)), Set((0..<9).map { "same-\($0)" }))
    }

    func testInMemoryPagingMatchesChronologicalPageContract() async throws {
        let store = InMemoryConversationStore()
        let conversation = try await store.createConversation(id: UUID(), title: "Memory", createdAt: Date())

        for index in 0..<7 {
            try await store.append(
                ChatMessage(
                    role: .user,
                    content: "m-\(index)",
                    timestamp: Date(timeIntervalSince1970: Double(index))
                ),
                conversationID: conversation.id
            )
        }

        let first = try await store.loadTranscriptPage(conversationID: conversation.id, before: nil, limit: 3)
        let second = try await store.loadTranscriptPage(conversationID: conversation.id, before: first.olderCursor, limit: 3)
        let third = try await store.loadTranscriptPage(conversationID: conversation.id, before: second.olderCursor, limit: 3)

        XCTAssertEqual(first.messages.map(\.content), ["m-4", "m-5", "m-6"])
        XCTAssertEqual(second.messages.map(\.content), ["m-1", "m-2", "m-3"])
        XCTAssertEqual(third.messages.map(\.content), ["m-0"])
        XCTAssertFalse(third.hasOlder)
    }

    func testDurableTranscriptNeverContainsSyntheticCompactionMessage() async throws {
        let conversationID = UUID()
        let store = InMemoryConversationStore()
        _ = try await store.createConversation(id: conversationID, title: "Long", createdAt: Date())
        let engine = LumiEngine(
            llm: PagingTestClient(),
            memory: MemoryStore(capacity: 10),
            conversationStore: store,
            conversationID: conversationID
        )

        for index in 0..<7 {
            _ = await engine.respond(to: "turn-\(index)", profile: "chat")
        }

        let workingContext = await engine.memory.all()
        XCTAssertEqual(workingContext.first?.role, .system, "Working context should contain compaction after overflow.")

        let durable = try await store.loadMessages(conversationID: conversationID)
        XCTAssertEqual(durable.count, 14)
        XCTAssertFalse(durable.contains(where: { $0.role == .system }))
        XCTAssertFalse(durable.contains(where: { $0.content.contains("Compacted earlier conversation context") }))
    }

    private func temporaryDatabase(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-\(prefix)-\(UUID().uuidString).sqlite3")
    }
}

private struct PagingTestClient: LLMClient {
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        ModelResponse(
            content: "ok",
            runtime: RuntimeMetadata(
                provider: .localFallback,
                model: "paging-test",
                fallbackUsed: true,
                finishReason: .stop
            )
        )
    }
}
