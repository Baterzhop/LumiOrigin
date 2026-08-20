import Foundation

public actor AgentRuntime {
    private let store: any ConversationStore
    private let model: any ModelProvider

    public private(set) var phase: RuntimePhase = .idle
    public private(set) var lastError: String?

    public init(store: any ConversationStore, model: any ModelProvider) {
        self.store = store
        self.model = model
    }

    public func send(
        _ text: String,
        conversationID: UUID,
        title: String = "New conversation"
    ) async throws -> RuntimeResponse {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw AgentRuntimeError.emptyInput
        }

        do {
            phase = .loadingConversation
            lastError = nil

            var conversation = try await store.loadConversation(id: conversationID)
                ?? Conversation(id: conversationID, title: title)

            if conversation.messages.isEmpty, conversation.title == "New conversation" {
                conversation.title = Self.makeTitle(from: normalized)
            }

            let userMessage = ChatMessage(role: .user, content: normalized)
            conversation.messages.append(userMessage)
            conversation.updatedAt = Date()

            // Persistence happens before model execution. If the model fails, the user's
            // input remains durable and the UI can accurately show what happened.
            phase = .persistingUserMessage
            try await store.saveConversation(conversation)

            phase = .waitingForModel
            let response = try await model.respond(to: ModelRequest(messages: conversation.messages))

            let assistantMessage = ChatMessage(role: .assistant, content: response.content)
            conversation.messages.append(assistantMessage)
            conversation.updatedAt = Date()

            phase = .persistingAssistantMessage
            try await store.saveConversation(conversation)

            phase = .idle
            return RuntimeResponse(
                conversation: conversation,
                assistantMessage: assistantMessage
            )
        } catch {
            phase = .failed
            lastError = String(describing: error)
            throw error
        }
    }

    public func loadConversation(id: UUID) async throws -> Conversation? {
        phase = .loadingConversation
        defer {
            if phase != .failed { phase = .idle }
        }
        return try await store.loadConversation(id: id)
    }

    private static func makeTitle(from text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        if singleLine.count <= 48 { return singleLine }
        return String(singleLine.prefix(45)) + "…"
    }
}

public enum AgentRuntimeError: Error, CustomStringConvertible, Sendable {
    case emptyInput

    public var description: String {
        switch self {
        case .emptyInput:
            return "Message cannot be empty."
        }
    }
}
