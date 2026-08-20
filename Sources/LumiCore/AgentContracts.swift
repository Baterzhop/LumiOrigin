import Foundation

public enum AgentRunState: String, Codable, Hashable, Sendable {
    case created
    case planning
    case executing
    case waitingForConfirmation
    case observing
    case replanning
    case completed
    case failed
    case cancelled
    case budgetExceeded
}

public struct AgentBudget: Codable, Hashable, Sendable {
    public let maxSteps: Int
    public let maxToolCalls: Int
    public let maxDurationSeconds: Int

    public init(
        maxSteps: Int = 8,
        maxToolCalls: Int = 6,
        maxDurationSeconds: Int = 60
    ) {
        self.maxSteps = max(1, min(maxSteps, 64))
        self.maxToolCalls = max(1, min(maxToolCalls, 32))
        self.maxDurationSeconds = max(1, min(maxDurationSeconds, 900))
    }
}

public indirect enum AgentJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .boolean(value); return }
        if let value = try? container.decode(Int.self) { self = .integer(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([AgentJSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: AgentJSONValue].self) { self = .object(value); return }
        throw DecodingError.typeMismatch(
            AgentJSONValue.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value.")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var toolValue: ToolValue {
        switch self {
        case .string(let value): return .string(value)
        case .integer(let value): return .integer(value)
        case .number(let value): return .number(value)
        case .boolean(let value): return .boolean(value)
        case .array(let value): return .array(value.map { $0.toolValue })
        case .object(let value): return .object(value.mapValues { $0.toolValue })
        case .null: return .null
        }
    }
}

public enum AgentDecision: Codable, Hashable, Sendable {
    case tool(name: String, arguments: [String: AgentJSONValue], note: String?)
    case finish(answer: String)
}

public struct AgentStep: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let index: Int
    public let call: ToolCall
    public let note: String?
    public let result: ToolResult
    public let startedAt: Date
    public let finishedAt: Date

    public init(
        id: UUID = UUID(),
        index: Int,
        call: ToolCall,
        note: String? = nil,
        result: ToolResult,
        startedAt: Date,
        finishedAt: Date = Date()
    ) {
        self.id = id
        self.index = index
        self.call = call
        self.note = note
        self.result = result
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public func replacing(result: ToolResult, finishedAt: Date = Date()) -> AgentStep {
        AgentStep(
            id: id,
            index: index,
            call: call,
            note: note,
            result: result,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }
}

public struct AgentRun: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let goal: String
    public let classification: RequestClassification?
    public let state: AgentRunState
    public let budget: AgentBudget
    public let steps: [AgentStep]
    public let pendingCall: ToolCall?
    public let finalAnswer: String?
    public let error: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        goal: String,
        classification: RequestClassification? = nil,
        state: AgentRunState = .created,
        budget: AgentBudget = AgentBudget(),
        steps: [AgentStep] = [],
        pendingCall: ToolCall? = nil,
        finalAnswer: String? = nil,
        error: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.goal = goal
        self.classification = classification
        self.state = state
        self.budget = budget
        self.steps = steps
        self.pendingCall = pendingCall
        self.finalAnswer = finalAnswer
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var toolCallCount: Int {
        steps.count
    }

    public func replacing(
        state: AgentRunState? = nil,
        steps: [AgentStep]? = nil,
        pendingCall: ToolCall?? = nil,
        finalAnswer: String?? = nil,
        error: String?? = nil,
        updatedAt: Date = Date()
    ) -> AgentRun {
        AgentRun(
            id: id,
            goal: goal,
            classification: classification,
            state: state ?? self.state,
            budget: budget,
            steps: steps ?? self.steps,
            pendingCall: pendingCall ?? self.pendingCall,
            finalAnswer: finalAnswer ?? self.finalAnswer,
            error: error ?? self.error,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public struct AgentPlanningContext: Sendable {
    public let run: AgentRun
    public let availableTools: [ToolDefinition]

    public init(run: AgentRun, availableTools: [ToolDefinition]) {
        self.run = run
        self.availableTools = availableTools
    }
}

public protocol AgentPlanning: Sendable {
    func decide(_ context: AgentPlanningContext) async throws -> AgentDecision
}

public protocol AgentRunStoring: Sendable {
    func save(_ run: AgentRun) async throws
    func load(id: UUID) async throws -> AgentRun?
    func recent(limit: Int) async throws -> [AgentRun]
}

public enum AgentRuntimeError: Error, LocalizedError, Sendable {
    case emptyGoal
    case runNotFound
    case invalidState(String)
    case plannerFailed(String)
    case invalidPlannerResponse(String)
    case confirmationMismatch
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyGoal: return "Agent goal is empty."
        case .runNotFound: return "Agent run was not found."
        case .invalidState(let detail): return "Agent run is in an invalid state: \(detail)"
        case .plannerFailed(let detail): return "Agent planner failed: \(detail)"
        case .invalidPlannerResponse(let detail): return "Agent planner returned an invalid response: \(detail)"
        case .confirmationMismatch: return "Confirmation does not match the pending agent tool call."
        case .persistenceFailed(let detail): return "Could not persist agent run: \(detail)"
        }
    }
}
