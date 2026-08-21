import Foundation

public extension LumiRuntimeContainer {
    /// Presentation/export read path. This bypasses compacted working memory and reads only durable
    /// user/assistant transcript rows from the shared conversation store.
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

    func fullTranscript(conversationID: UUID) async throws -> [ChatMessage] {
        try await conversationStore.loadMessages(conversationID: conversationID)
    }
}
