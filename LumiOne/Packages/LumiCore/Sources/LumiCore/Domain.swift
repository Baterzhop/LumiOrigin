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

/// Durable representation of a completed or denied tool operation.
/// It contains enough protocol information to reconstruct a valid
/// `assistant tool_call -> tool result` exchange for OpenAI-compatible models.
public struct ToolHistoryEvent: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case success
        case denied
    }

    public let status: Status
    public let callID: UUID
    public let providerCallID: String
    public let tool: String
    public let version: String
    public let arguments: JSONValue
    public let data: JSONValue?
    public let warnings: [ToolWarning]
    public let metadata: [String: JSONValue]
    public let detail: String?

    public init(
        status: Status,
        callID: UUID,
        providerCallID: String,
        tool: String,
        version: String,
        arguments: JSONValue,
        data: JSONValue? = nil,
        warnings: [ToolWarning] = [],
        metadata: [String: JSONValue] = [:],
        detail: String? = nil
    ) {
        self.status = status
        self.callID = callID
        self.providerCallID = providerCallID
        self.tool = tool
        self.version = version
        self.arguments = arguments
        self.data = data
        self.warnings = warnings
        self.metadata = metadata
        self.detail = detail
    }
}

public enum RuntimePhase: String, Codable, Sendable {
    case idle
    case loadingConversation
    case persistingUserMessage
    case waitingForModel
    case executingTool
    case awaitingPermission
    case persistingToolResult
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

public struct PendingToolApproval: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let conversation: Conversation
    public let permission: PermissionRequest
    public let toolName: String
    public let toolVersion: String
    public let createdAt: Date

    public init(
        id: UUID,
        conversation: Conversation,
        permission: PermissionRequest,
        toolName: String,
        toolVersion: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversation = conversation
        self.permission = permission
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.createdAt = createdAt
    }
}

public enum RuntimeOutcome: Sendable {
    case completed(RuntimeResponse)
    case permissionRequired(PendingToolApproval)
}
