import Foundation

public enum ExecutionMode: String, Codable, Sendable, CaseIterable, Hashable {
    case direct
    case knowledge
    case agent
}

public enum LumiCapability: String, Codable, Sendable, CaseIterable, Hashable {
    case reasoning
    case retrieval
    case coding
    case tools
    case reflection
    case memory
    case files
    case web
}

public enum RiskLevel: String, Codable, Sendable, CaseIterable, Hashable {
    case low
    case medium
    case high
}

public struct LumiRequest: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let input: String
    public let profileOverride: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        input: String,
        profileOverride: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.input = input
        self.profileOverride = profileOverride
        self.createdAt = createdAt
    }
}

public struct RequestClassification: Codable, Hashable, Sendable {
    public let mode: ExecutionMode
    public let capabilities: Set<LumiCapability>
    public let confidence: Double
    public let risk: RiskLevel

    public init(
        mode: ExecutionMode,
        capabilities: Set<LumiCapability> = [],
        confidence: Double = 1,
        risk: RiskLevel = .low
    ) {
        self.mode = mode
        self.capabilities = capabilities
        self.confidence = min(max(confidence, 0), 1)
        self.risk = risk
    }
}

public enum ModelProvider: String, Codable, Sendable, Hashable {
    case ollama
    case localFallback
    case unknown
}

public enum ModelFinishReason: String, Codable, Sendable, Hashable {
    case stop
    case length
    case cancelled
    case error
    case unknown
}

public struct ModelUsage: Codable, Hashable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct RuntimeMetadata: Codable, Hashable, Sendable {
    public let provider: ModelProvider
    public let model: String
    public let fallbackUsed: Bool
    public let latencyMs: Int?
    public let finishReason: ModelFinishReason
    public let usage: ModelUsage

    public init(
        provider: ModelProvider,
        model: String,
        fallbackUsed: Bool = false,
        latencyMs: Int? = nil,
        finishReason: ModelFinishReason = .unknown,
        usage: ModelUsage = ModelUsage()
    ) {
        self.provider = provider
        self.model = model
        self.fallbackUsed = fallbackUsed
        self.latencyMs = latencyMs
        self.finishReason = finishReason
        self.usage = usage
    }
}

public struct ModelResponse: Codable, Hashable, Sendable {
    public let content: String
    public let runtime: RuntimeMetadata

    public init(content: String, runtime: RuntimeMetadata) {
        self.content = content
        self.runtime = runtime
    }
}

public enum ModelEvent: Sendable, Hashable {
    case token(String)
    case completed(ModelResponse)
}

public enum LumiRuntimeError: Error, LocalizedError, Sendable {
    case emptyInput
    case providerUnavailable(String)
    case modelUnavailable(String)
    case unauthorized
    case rateLimited
    case timeout
    case contextOverflow
    case invalidResponse
    case decodingFailure(String)
    case cancelled
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput: return "The request is empty."
        case .providerUnavailable(let provider): return "Model provider is unavailable: \(provider)."
        case .modelUnavailable(let model): return "Model is unavailable: \(model)."
        case .unauthorized: return "The model provider rejected authorization."
        case .rateLimited: return "The model provider rate limit was reached."
        case .timeout: return "The model request timed out."
        case .contextOverflow: return "The request exceeded the model context window."
        case .invalidResponse: return "The model returned an invalid response."
        case .decodingFailure(let detail): return "Could not decode the model response: \(detail)."
        case .cancelled: return "The model request was cancelled."
        case .unknown(let detail): return detail
        }
    }
}
