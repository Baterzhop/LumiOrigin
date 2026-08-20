import Foundation

struct ChatRequestDTO: Encodable, Sendable {
    let message: String
    let conversationID: String?

    enum CodingKeys: String, CodingKey {
        case message
        case conversationID = "conversation_id"
    }
}

public enum StreamEventType: String, Decodable, Sendable {
    case started
    case delta
    case completed
    case cancelled
    case error
}

public struct ChatStreamEvent: Decodable, Sendable {
    public let type: StreamEventType
    public let generationID: String
    public let conversationID: String
    public let delta: String?
    public let content: String?
    public let messageID: String?
    public let provider: String?
    public let model: String?
    public let fallback: Bool?
    public let error: String?
    public let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case type
        case generationID = "generation_id"
        case conversationID = "conversation_id"
        case delta
        case content
        case messageID = "message_id"
        case provider
        case model
        case fallback
        case error
        case finishReason = "finish_reason"
    }
}

public struct HealthResponse: Decodable, Sendable {
    public let ok: Bool
    public let service: String
    public let version: String
}

public struct RuntimeStatusResponse: Decodable, Sendable {
    public let ok: Bool
    public let streaming: Bool
    public let provider: String
    public let model: String
    public let activeGenerations: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case streaming
        case provider
        case model
        case activeGenerations = "active_generations"
    }
}
