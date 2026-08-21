import Foundation

public extension LumiRuntimeContainer {
    func transcriptPage(
        conversationID: UUID,
        before cursor: ConversationTranscriptCursor? = nil,
        limit: Int = 60
    ) async throws -> ConversationTranscriptPage {
        try await conversationStore.loadTranscriptPage(
            conversationID: conversationID,
            before: cursor,
            limit: max(1, min(limit, 500))
        )
    }
}

public extension LumiEngine {
    /// Durable transcript for presentation/export. This intentionally bypasses compacted working
    /// context so synthetic summary records can never appear as user-visible chat messages.
    func durableTranscript() async throws -> [ChatMessage] {
        try await conversationStore.loadMessages(conversationID: conversationID)
    }

    func transcriptPage(
        before cursor: ConversationTranscriptCursor? = nil,
        limit: Int = 60
    ) async throws -> ConversationTranscriptPage {
        try await conversationStore.loadTranscriptPage(
            conversationID: conversationID,
            before: cursor,
            limit: max(1, min(limit, 500))
        )
    }
}
