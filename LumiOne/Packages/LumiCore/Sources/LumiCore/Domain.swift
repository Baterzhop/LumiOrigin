import Foundation

public enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let role: ChatRole
    public let content: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public struct Conversation: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]

    public init(
        id: UUID = UUID(),
        title: String = "New conversation",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

public enum RuntimePhase: String, Codable, Sendable {
    case idle
    case loadingConversation
    case persistingUserMessage
    case waitingForModel
    case persistingAssistantMessage
    case failed
}

public struct RuntimeResponse: Sendable {
    public let conversation: Conversation
    public let assistantMessage: ChatMessage

    public init(conversation: Conversation, assistantMessage: ChatMessage) {
        self.conversation = conversation
        self.assistantMessage = assistantMessage
    }
}
