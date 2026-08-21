import Foundation

public enum RuntimeTraceOutcome: String, Codable, Hashable, Sendable {
    case completed
    case modelError
    case contextOverflow
    case cancelled
}

/// Metadata-only trace for one Lumi generation request.
/// Prompt, response, retrieved text and memory contents are intentionally not stored.
public struct RuntimeTrace: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let requestID: UUID
    public let conversationID: UUID
    public let createdAt: Date
    public let durationMs: Int
    public let outcome: RuntimeTraceOutcome
    public let mode: ExecutionMode
    public let capabilities: Set<LumiCapability>
    public let risk: RiskLevel
    public let classificationConfidence: Double
    public let profile: String
    public let provider: ModelProvider
    public let model: String
    public let modelRole: ModelRole?
    public let fallbackUsed: Bool
    public let modelLatencyMs: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let contextWindow: Int
    public let contextInputBudgetTokens: Int
    public let estimatedContextTokens: Int
    public let historyTokens: Int
    public let memoryTokens: Int
    public let knowledgeTokens: Int
    public let selectedMessageCount: Int
    public let selectedMemoryCount: Int
    public let selectedKnowledgeCount: Int
    public let droppedMessageCount: Int
    public let droppedMemoryCount: Int
    public let droppedKnowledgeCount: Int
    public let citationCount: Int
    public let invalidCitationCount: Int
    public let uncitedEvidenceCount: Int

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        conversationID: UUID,
        createdAt: Date = Date(),
        durationMs: Int,
        outcome: RuntimeTraceOutcome,
        classification: RequestClassification,
        profile: String,
        runtime: RuntimeMetadata,
        contextBudget: ContextBudgetReport,
        citationReport: CitationReport
    ) {
        self.id = id
        self.requestID = requestID
        self.conversationID = conversationID
        self.createdAt = createdAt
        self.durationMs = max(0, durationMs)
        self.outcome = outcome
        self.mode = classification.mode
        self.capabilities = classification.capabilities
        self.risk = classification.risk
        self.classificationConfidence = classification.confidence
        self.profile = profile
        self.provider = runtime.provider
        self.model = runtime.model
        self.modelRole = runtime.modelRole
        self.fallbackUsed = runtime.fallbackUsed
        self.modelLatencyMs = runtime.latencyMs
        self.inputTokens = runtime.usage.inputTokens
        self.outputTokens = runtime.usage.outputTokens
        self.contextWindow = contextBudget.contextWindow
        self.contextInputBudgetTokens = contextBudget.inputBudgetTokens
        self.estimatedContextTokens = contextBudget.estimatedInputTokens
        self.historyTokens = contextBudget.historyTokens
        self.memoryTokens = contextBudget.memoryTokens
        self.knowledgeTokens = contextBudget.knowledgeTokens
        self.selectedMessageCount = contextBudget.selectedMessageCount
        self.selectedMemoryCount = contextBudget.selectedMemoryCount
        self.selectedKnowledgeCount = contextBudget.selectedKnowledgeCount
        self.droppedMessageCount = contextBudget.droppedMessageCount
        self.droppedMemoryCount = contextBudget.droppedMemoryCount
        self.droppedKnowledgeCount = contextBudget.droppedKnowledgeCount
        self.citationCount = citationReport.citations.count
        self.invalidCitationCount = citationReport.invalidMarkers.count
        self.uncitedEvidenceCount = citationReport.uncitedEvidenceCount
    }
}

public protocol RuntimeTraceStoring: Sendable {
    func append(_ trace: RuntimeTrace) async throws
    func recent(limit: Int) async throws -> [RuntimeTrace]
    func clear() async throws
}

public actor RuntimeTelemetry {
    private let store: any RuntimeTraceStoring
    private var lastIssue: String?

    public init(store: any RuntimeTraceStoring = InMemoryRuntimeTraceStore()) {
        self.store = store
    }

    public func record(_ trace: RuntimeTrace) async {
        do {
            try await store.append(trace)
            lastIssue = nil
        } catch {
            lastIssue = error.localizedDescription
        }
    }

    public func recent(limit: Int = 100) async -> [RuntimeTrace] {
        do {
            let traces = try await store.recent(limit: max(0, limit))
            lastIssue = nil
            return traces
        } catch {
            lastIssue = error.localizedDescription
            return []
        }
    }

    public func clear() async {
        do {
            try await store.clear()
            lastIssue = nil
        } catch {
            lastIssue = error.localizedDescription
        }
    }

    public func issue() -> String? {
        lastIssue
    }
}

public actor InMemoryRuntimeTraceStore: RuntimeTraceStoring {
    private var traces: [RuntimeTrace] = []

    public init() {}

    public func append(_ trace: RuntimeTrace) {
        traces.append(trace)
    }

    public func recent(limit: Int) -> [RuntimeTrace] {
        Array(traces.suffix(max(0, limit)).reversed())
    }

    public func clear() {
        traces.removeAll(keepingCapacity: false)
    }
}
