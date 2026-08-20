import Foundation

/// Supplies ephemeral read-only evidence for one user turn.
/// Implementations must not mutate chat history, permissions, tools or Knowledge.
public protocol ModelContextProvider: Sendable {
    func context(for query: String) async throws -> GroundedContext?
}

/// Bridges durable Knowledge retrieval into an ephemeral model context snapshot.
/// The snapshot is built once by AgentRuntime and reused unchanged for the rest
/// of that user turn, including any permission/tool pause and resume cycle.
public struct KnowledgeModelContextProvider: ModelContextProvider, Sendable {
    private let retriever: any KnowledgeRetriever
    private let builder: GroundedContextBuilder

    public init(
        retriever: any KnowledgeRetriever,
        builder: GroundedContextBuilder = GroundedContextBuilder()
    ) {
        self.retriever = retriever
        self.builder = builder
    }

    public func context(for query: String) async throws -> GroundedContext? {
        let hits = try await retriever.search(
            query,
            maxHits: builder.configuration.maxHits
        )
        guard !hits.isEmpty else { return nil }

        let context = try builder.build(from: hits)
        return context.entries.isEmpty ? nil : context
    }
}
