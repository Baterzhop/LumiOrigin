import Foundation

struct ChatRequestDTO: Encodable, Sendable {
    let message: String
    let conversationID: String?

    enum CodingKeys: String, CodingKey {
        case message
        case conversationID = "conversation_id"
    }
}

enum StreamEventType: String, Decodable, Sendable {
    case started
    case delta
    case completed
    case cancelled
    case error
}

struct ChatStreamEvent: Decodable, Sendable {
    let type: StreamEventType
    let generationID: String
    let conversationID: String
    let delta: String?
    let content: String?
    let messageID: String?
    let provider: String?
    let model: String?
    let fallback: Bool?
    let error: String?
    let finishReason: String?

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

struct HealthResponse: Decodable, Sendable {
    let ok: Bool
    let service: String
    let version: String
}

struct RuntimeStatusResponse: Decodable, Sendable {
    let ok: Bool
    let streaming: Bool
    let provider: String
    let model: String
    let activeGenerations: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case streaming
        case provider
        case model
        case activeGenerations = "active_generations"
    }
}

struct ChatBubble: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var content: String
    var provider: String?
    var model: String?
    var finishReason: String?

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        provider: String? = nil,
        model: String? = nil,
        finishReason: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.provider = provider
        self.model = model
        self.finishReason = finishReason
    }
}
