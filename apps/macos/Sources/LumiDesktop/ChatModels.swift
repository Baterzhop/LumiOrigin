import Foundation

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
