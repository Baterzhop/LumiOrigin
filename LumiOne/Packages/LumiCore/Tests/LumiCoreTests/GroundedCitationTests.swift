import Foundation
import XCTest
@testable import LumiCore

final class GroundedCitationTests: XCTestCase {
    func testResolverReturnsValidatedCitationsInFirstUseOrderWithoutDuplicates() throws {
        let context = citationContext()
        let citations = try GroundedCitationResolver().resolve(
            in: "Second source [K2], first source [K1], repeated [K2].",
            context: context
        )

        XCTAssertEqual(citations.map(\.label), ["K2", "K1"])
        XCTAssertEqual(citations[0].displayName, "Second.pdf")
        XCTAssertEqual(citations[0].pageStart, 9)
        XCTAssertEqual(citations[1].displayName, "First.pdf")
        XCTAssertEqual(citations[1].pageStart, 3)
    }

    func testUnknownCitationLabelFailsClosed() throws {
        let context = citationContext()

        XCTAssertThrowsError(
            try GroundedCitationResolver().resolve(
                in: "Supported [K1], hallucinated [K99].",
                context: context
            )
        ) { error in
            XCTAssertEqual(
                error as? GroundedCitationError,
                .unknownLabels(["K99"])
            )
        }
    }

    func testCitationMarkerWithoutAnyGroundedContextFailsClosed() throws {
        XCTAssertThrowsError(
            try GroundedCitationResolver().resolve(
                in: "There is no source, but here is [K1].",
                context: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? GroundedCitationError,
                .unknownLabels(["K1"])
            )
        }
    }

    func testAgentRuntimeDoesNotPersistAssistantMessageWithHallucinatedCitation() async throws {
        let context = citationContext()
        let provider = CitationFixedContextProvider(context: context)
        let model = CitationFinalModel(content: "Hallucinated source [K99]")
        let store = CitationMemoryStore()
        let runtime = AgentRuntime(
            store: store,
            model: model,
            contextProvider: provider
        )
        let conversationID = UUID()

        do {
            _ = try await runtime.send("Use my indexed document", conversationID: conversationID)
            XCTFail("Unknown citation should reject the final model response")
        } catch let error as GroundedCitationError {
            XCTAssertEqual(error, .unknownLabels(["K99"]))
        }

        let durable = try await store.loadConversation(id: conversationID)
        XCTAssertEqual(durable?.messages.count, 1)
        XCTAssertEqual(durable?.messages.first?.role, .user)
        XCTAssertEqual(durable?.messages.first?.content, "Use my indexed document")
    }

    func testAgentRuntimeReturnsStructuredValidatedCitationMetadata() async throws {
        let context = citationContext()
        let provider = CitationFixedContextProvider(context: context)
        let model = CitationFinalModel(content: "Answer from the first document [K1].")
        let store = CitationMemoryStore()
        let runtime = AgentRuntime(
            store: store,
            model: model,
            contextProvider: provider
        )

        let outcome = try await runtime.send("Question", conversationID: UUID())
        guard case .completed(let response) = outcome else {
            return XCTFail("Expected completed grounded answer")
        }

        XCTAssertEqual(response.citations.count, 1)
        XCTAssertEqual(response.citations[0].label, "K1")
        XCTAssertEqual(response.citations[0].displayName, "First.pdf")
        XCTAssertEqual(response.citations[0].pageStart, 3)
        XCTAssertEqual(response.citations[0].pageEnd, 4)
    }

    private func citationContext() -> GroundedContext {
        let first = citationEntry(
            label: "K1",
            document: "A0000000-0000-0000-0000-000000000001",
            chunk: "A0000000-0000-0000-0000-000000000101",
            source: "first-source",
            name: "First.pdf",
            pageStart: 3,
            pageEnd: 4,
            text: "First source evidence"
        )
        let second = citationEntry(
            label: "K2",
            document: "B0000000-0000-0000-0000-000000000001",
            chunk: "B0000000-0000-0000-0000-000000000101",
            source: "second-source",
            name: "Second.pdf",
            pageStart: 9,
            pageEnd: 9,
            text: "Second source evidence"
        )
        return GroundedContext(
            entries: [first, second],
            renderedText: "fixture-grounded-context"
        )
    }

    private func citationEntry(
        label: String,
        document: String,
        chunk: String,
        source: String,
        name: String,
        pageStart: Int,
        pageEnd: Int,
        text: String
    ) -> GroundedContextEntry {
        GroundedContextEntry(
            citation: KnowledgeCitation(
                label: label,
                documentID: UUID(uuidString: document)!,
                sourceResourceID: UserFileResourceID(rawValue: source),
                displayName: name,
                chunkID: UUID(uuidString: chunk)!,
                chunkOrdinal: 0,
                pageStart: pageStart,
                pageEnd: pageEnd
            ),
            score: 1,
            text: text
        )
    }
}

private actor CitationFixedContextProvider: ModelContextProvider {
    let value: GroundedContext

    init(context: GroundedContext) {
        value = context
    }

    func context(for query: String) async throws -> GroundedContext? {
        value
    }
}

private actor CitationFinalModel: ModelProvider {
    let content: String

    init(content: String) {
        self.content = content
    }

    func respond(to request: ModelRequest) async throws -> ModelTurn {
        .final(content)
    }
}

private actor CitationMemoryStore: ConversationStore {
    private var conversations: [UUID: Conversation] = [:]

    func loadConversation(id: UUID) async throws -> Conversation? {
        conversations[id]
    }

    func saveConversation(_ conversation: Conversation) async throws {
        conversations[conversation.id] = conversation
    }
}
