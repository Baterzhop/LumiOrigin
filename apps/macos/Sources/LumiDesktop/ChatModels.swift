import Foundation
import LumiClientCore

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
    var citations: [CitationDTO]

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        provider: String? = nil,
        model: String? = nil,
        finishReason: String? = nil,
        citations: [CitationDTO] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.provider = provider
        self.model = model
        self.finishReason = finishReason
        self.citations = citations
    }
}
