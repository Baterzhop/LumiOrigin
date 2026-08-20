import Foundation

/// Immutable ephemeral context for one user turn.
///
/// Knowledge and user memory remain separate provenance domains with separate
/// budgets. AgentRuntime builds this snapshot once and reuses it unchanged for
/// the entire model/tool/permission cycle.
public struct ModelContextSnapshot: Equatable, Sendable {
    public let groundedKnowledge: GroundedContext?
    public let userMemory: MemoryContext?

    public init(
        groundedKnowledge: GroundedContext? = nil,
        userMemory: MemoryContext? = nil
    ) {
        self.groundedKnowledge = groundedKnowledge
        self.userMemory = userMemory
    }

    public var isEmpty: Bool {
        groundedKnowledge == nil && userMemory == nil
    }
}

/// Supplies ephemeral read-only context for one user turn.
/// Implementations must not mutate chat history, permissions, tools, Knowledge
/// or Memory while building the snapshot.
public protocol ModelContextProvider: Sendable {
    func context(for query: String) async throws -> ModelContextSnapshot?
}

/// Bridges durable Knowledge retrieval into an ephemeral model context snapshot.
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

    public func context(for query: String) async throws -> ModelContextSnapshot? {
        let hits = try await retriever.search(
            query,
            maxHits: builder.configuration.maxHits
        )
        guard !hits.isEmpty else { return nil }

        let context = try builder.build(from: hits)
        guard !context.entries.isEmpty else { return nil }
        return ModelContextSnapshot(groundedKnowledge: context)
    }
}

/// Bridges durable user-memory retrieval into a lower-authority ephemeral
/// context block. It never writes or consolidates memory.
public struct MemoryModelContextProvider: ModelContextProvider, Sendable {
    private let retriever: any MemoryRetriever
    private let builder: MemoryContextBuilder

    public init(
        retriever: any MemoryRetriever,
        builder: MemoryContextBuilder = MemoryContextBuilder()
    ) {
        self.retriever = retriever
        self.builder = builder
    }

    public func context(for query: String) async throws -> ModelContextSnapshot? {
        let hits = try await retriever.search(
            query,
            maxHits: builder.configuration.maxHits
        )
        guard !hits.isEmpty else { return nil }

        let context = try builder.build(from: hits)
        guard !context.entries.isEmpty else { return nil }
        return ModelContextSnapshot(userMemory: context)
    }
}

/// Combines independently-budgeted providers without merging provenance.
/// Provider order has no authority meaning; it only determines evaluation order.
public struct CompositeModelContextProvider: ModelContextProvider, Sendable {
    private let knowledgeProvider: (any ModelContextProvider)?
    private let memoryProvider: (any ModelContextProvider)?

    public init(
        knowledgeProvider: (any ModelContextProvider)? = nil,
        memoryProvider: (any ModelContextProvider)? = nil
    ) {
        self.knowledgeProvider = knowledgeProvider
        self.memoryProvider = memoryProvider
    }

    public func context(for query: String) async throws -> ModelContextSnapshot? {
        let knowledge = try await knowledgeProvider?.context(for: query)
        let memory = try await memoryProvider?.context(for: query)

        let snapshot = ModelContextSnapshot(
            groundedKnowledge: knowledge?.groundedKnowledge,
            userMemory: memory?.userMemory
        )
        return snapshot.isEmpty ? nil : snapshot
    }
}
