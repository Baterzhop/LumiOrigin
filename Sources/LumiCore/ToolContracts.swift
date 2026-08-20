import Foundation

public indirect enum ToolValue: Codable, Hashable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case array([ToolValue])
    case object([String: ToolValue])
    case null

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

public enum ToolValueType: String, Codable, Hashable, Sendable {
    case string
    case integer
    case number
    case boolean
    case array
    case object
}

public struct ToolFieldSchema: Codable, Hashable, Sendable {
    public let name: String
    public let type: ToolValueType
    public let description: String
    public let required: Bool

    public init(name: String, type: ToolValueType, description: String, required: Bool = true) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }
}

public enum ToolAccess: String, Codable, Hashable, Sendable {
    case readOnly
    case write
    case destructive
}

public struct ToolDefinition: Codable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: [ToolFieldSchema]
    public let outputDescription: String
    public let access: ToolAccess
    public let risk: RiskLevel
    public let requiresConfirmation: Bool
    public let timeoutSeconds: Int

    public init(
        name: String,
        description: String,
        inputSchema: [ToolFieldSchema] = [],
        outputDescription: String,
        access: ToolAccess,
        risk: RiskLevel,
        requiresConfirmation: Bool = false,
        timeoutSeconds: Int = 10
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputDescription = outputDescription
        self.access = access
        self.risk = risk
        self.requiresConfirmation = requiresConfirmation
        self.timeoutSeconds = max(1, min(timeoutSeconds, 120))
    }
}

public enum ToolCallOrigin: String, Codable, Hashable, Sendable {
    case user
    case agent
    case system
}

public struct ToolCall: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let toolName: String
    public let arguments: [String: ToolValue]
    public let origin: ToolCallOrigin
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        toolName: String,
        arguments: [String: ToolValue] = [:],
        origin: ToolCallOrigin,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.origin = origin
        self.createdAt = createdAt
    }
}

public struct ToolConfirmation: Codable, Hashable, Sendable {
    public let callID: UUID
    public let approved: Bool
    public let confirmedAt: Date

    public init(callID: UUID, approved: Bool, confirmedAt: Date = Date()) {
        self.callID = callID
        self.approved = approved
        self.confirmedAt = confirmedAt
    }
}

public enum ToolPermissionStatus: String, Codable, Hashable, Sendable {
    case allowed
    case confirmationRequired
    case denied
}

public struct ToolPermissionDecision: Codable, Hashable, Sendable {
    public let status: ToolPermissionStatus
    public let reason: String

    public init(status: ToolPermissionStatus, reason: String) {
        self.status = status
        self.reason = reason
    }

    public static func allow(_ reason: String) -> ToolPermissionDecision {
        ToolPermissionDecision(status: .allowed, reason: reason)
    }

    public static func requireConfirmation(_ reason: String) -> ToolPermissionDecision {
        ToolPermissionDecision(status: .confirmationRequired, reason: reason)
    }

    public static func deny(_ reason: String) -> ToolPermissionDecision {
        ToolPermissionDecision(status: .denied, reason: reason)
    }
}

public enum ToolResultStatus: String, Codable, Hashable, Sendable {
    case success
    case denied
    case confirmationRequired
    case failed
    case timeout
    case cancelled
}

public enum ToolOutputTrust: String, Codable, Hashable, Sendable {
    case untrusted
}

public struct ToolResult: Codable, Hashable, Sendable {
    public let callID: UUID
    public let toolName: String
    public let status: ToolResultStatus
    public let output: ToolValue?
    public let error: String?
    public let durationMs: Int?
    public let trust: ToolOutputTrust

    public init(
        callID: UUID,
        toolName: String,
        status: ToolResultStatus,
        output: ToolValue? = nil,
        error: String? = nil,
        durationMs: Int? = nil,
        trust: ToolOutputTrust = .untrusted
    ) {
        self.callID = callID
        self.toolName = toolName
        self.status = status
        self.output = output
        self.error = error
        self.durationMs = durationMs
        self.trust = trust
    }
}

public struct ToolAuditEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let call: ToolCall
    public let definition: ToolDefinition?
    public let permission: ToolPermissionDecision
    public let resultStatus: ToolResultStatus
    public let error: String?
    public let startedAt: Date
    public let finishedAt: Date

    public init(
        id: UUID = UUID(),
        call: ToolCall,
        definition: ToolDefinition?,
        permission: ToolPermissionDecision,
        resultStatus: ToolResultStatus,
        error: String?,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.id = id
        self.call = call
        self.definition = definition
        self.permission = permission
        self.resultStatus = resultStatus
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public enum ToolRuntimeError: Error, LocalizedError, Sendable {
    case toolNotFound(String)
    case invalidArguments(String)
    case permissionDenied(String)
    case confirmationRequired(String)
    case timeout
    case cancelled
    case sandboxViolation(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let name): return "Tool not found: \(name)."
        case .invalidArguments(let detail): return "Invalid tool arguments: \(detail)"
        case .permissionDenied(let detail): return "Tool permission denied: \(detail)"
        case .confirmationRequired(let detail): return "Tool confirmation is required: \(detail)"
        case .timeout: return "Tool execution timed out."
        case .cancelled: return "Tool execution was cancelled."
        case .sandboxViolation(let detail): return "Tool sandbox rejected the operation: \(detail)"
        case .executionFailed(let detail): return "Tool execution failed: \(detail)"
        }
    }
}

public protocol LumiTool: Sendable {
    var definition: ToolDefinition { get }
    func execute(arguments: [String: ToolValue]) async throws -> ToolValue
}

public protocol ToolAuditStoring: Sendable {
    func append(_ event: ToolAuditEvent) async throws
    func recent(limit: Int) async throws -> [ToolAuditEvent]
}
