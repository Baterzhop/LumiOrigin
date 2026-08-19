import Foundation

public enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let role: ChatRole
    public let content: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

public enum LumiIntent: String, Codable, Sendable, CaseIterable {
    case chat
    case knowledge
    case coding
    case tool
    case reflection
}

public struct PromptProfile: Codable, Hashable, Sendable {
    public let name: String
    public let system: String
    public let temperature: Double
    public let topP: Double
    public let maxTokens: Int

    public init(
        name: String,
        system: String,
        temperature: Double,
        topP: Double = 0.9,
        maxTokens: Int = 1_024
    ) {
        self.name = name
        self.system = system
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }
}

public struct KnowledgeDocument: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let text: String
    public let tags: [String]

    public init(id: String, title: String, text: String, tags: [String] = []) {
        self.id = id
        self.title = title
        self.text = text
        self.tags = tags
    }
}

public struct KnowledgeHit: Codable, Hashable, Sendable {
    public let document: KnowledgeDocument
    public let score: Double

    public init(document: KnowledgeDocument, score: Double) {
        self.document = document
        self.score = score
    }
}

public struct ReflectionEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let input: String
    public let intent: LumiIntent
    public let responsePreview: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        input: String,
        intent: LumiIntent,
        responsePreview: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.input = input
        self.intent = intent
        self.responsePreview = responsePreview
        self.timestamp = timestamp
    }
}

public struct LumiReply: Sendable {
    public let message: ChatMessage
    public let intent: LumiIntent
    public let context: [KnowledgeHit]
    public let profile: String

    public init(message: ChatMessage, intent: LumiIntent, context: [KnowledgeHit], profile: String) {
        self.message = message
        self.intent = intent
        self.context = context
        self.profile = profile
    }
}
