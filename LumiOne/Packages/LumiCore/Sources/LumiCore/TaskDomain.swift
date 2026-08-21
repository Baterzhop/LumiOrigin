import Foundation

public struct TaskID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
    public var description: String { rawValue.uuidString.lowercased() }
}

public enum TaskState: String, Codable, CaseIterable, Sendable {
    case draft
    case ready
    case running
    case waitingForPermission
    case interrupted
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool { self == .succeeded || self == .cancelled }
    public var isEditable: Bool {
        switch self {
        case .draft, .ready, .interrupted, .failed: return true
        case .running, .waitingForPermission, .succeeded, .cancelled: return false
        }
    }
}

public enum TaskMutationActor: String, Codable, Sendable {
    case user
    case approvedModel
    case runner
    case recovery
    case system
}

public enum TaskEventKind: String, Codable, Sendable {
    case created
    case edited
    case transitioned
    case recovered
}

public struct TaskOrigin: Codable, Equatable, Sendable {
    public let conversationID: UUID?
    public let messageID: UUID?
    public init(conversationID: UUID? = nil, messageID: UUID? = nil) {
        self.conversationID = conversationID
        self.messageID = messageID
    }
}

public struct TaskRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: TaskID
    public let title: String
    public let instruction: String
    public let state: TaskState
    public let revision: Int
    public let attemptCount: Int
    public let maxAttempts: Int
    public let nextEligibleAt: Date?
    public let lastError: String?
    public let resultSummary: String?
    public let origin: TaskOrigin
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: TaskID, title: String, instruction: String, state: TaskState, revision: Int, attemptCount: Int, maxAttempts: Int, nextEligibleAt: Date?, lastError: String?, resultSummary: String?, origin: TaskOrigin, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.state = state
        self.revision = revision
        self.attemptCount = attemptCount
        self.maxAttempts = maxAttempts
        self.nextEligibleAt = nextEligibleAt
        self.lastError = lastError
        self.resultSummary = resultSummary
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TaskEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: TaskID
    public let revision: Int
    public let kind: TaskEventKind
    public let actor: TaskMutationActor
    public let fromState: TaskState?
    public let toState: TaskState
    public let reason: String?
    public let createdAt: Date

    public init(id: UUID = UUID(), taskID: TaskID, revision: Int, kind: TaskEventKind, actor: TaskMutationActor, fromState: TaskState?, toState: TaskState, reason: String?, createdAt: Date = Date()) {
        self.id = id
        self.taskID = taskID
        self.revision = revision
        self.kind = kind
        self.actor = actor
        self.fromState = fromState
        self.toState = toState
        self.reason = reason
        self.createdAt = createdAt
    }
}

public struct TaskCreateRequest: Equatable, Sendable {
    public let title: String
    public let instruction: String
    public let maxAttempts: Int
    public let nextEligibleAt: Date?
    public let origin: TaskOrigin
    public let actor: TaskMutationActor

    public init(title: String, instruction: String, maxAttempts: Int = 3, nextEligibleAt: Date? = nil, origin: TaskOrigin = TaskOrigin(), actor: TaskMutationActor) {
        self.title = title
        self.instruction = instruction
        self.maxAttempts = maxAttempts
        self.nextEligibleAt = nextEligibleAt
        self.origin = origin
        self.actor = actor
    }
}

public struct TaskEditRequest: Equatable, Sendable {
    public let id: TaskID
    public let title: String
    public let instruction: String
    public let maxAttempts: Int
    public let nextEligibleAt: Date?
    public let expectedRevision: Int
    public let actor: TaskMutationActor
    public let reason: String?

    public init(id: TaskID, title: String, instruction: String, maxAttempts: Int, nextEligibleAt: Date?, expectedRevision: Int, actor: TaskMutationActor, reason: String? = nil) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.maxAttempts = maxAttempts
        self.nextEligibleAt = nextEligibleAt
        self.expectedRevision = expectedRevision
        self.actor = actor
        self.reason = reason
    }
}

public struct TaskTransitionRequest: Equatable, Sendable {
    public let id: TaskID
    public let toState: TaskState
    public let expectedRevision: Int
    public let actor: TaskMutationActor
    public let reason: String?
    public let lastError: String?
    public let resultSummary: String?

    public init(id: TaskID, toState: TaskState, expectedRevision: Int, actor: TaskMutationActor, reason: String? = nil, lastError: String? = nil, resultSummary: String? = nil) {
        self.id = id
        self.toState = toState
        self.expectedRevision = expectedRevision
        self.actor = actor
        self.reason = reason
        self.lastError = lastError
        self.resultSummary = resultSummary
    }
}

public enum TaskValidation {
    public static let maximumTitleCharacters = 160
    public static let maximumInstructionCharacters = 12_000
    public static let maximumDetailCharacters = 4_000
    public static let maximumAttempts = 10

    public static func title(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= maximumTitleCharacters else { throw TaskStoreError.invalidTitle }
        return normalized
    }

    public static func instruction(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= maximumInstructionCharacters else { throw TaskStoreError.invalidInstruction }
        return normalized
    }

    public static func detail(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= maximumDetailCharacters else { throw TaskStoreError.detailTooLong }
        return normalized.isEmpty ? nil : normalized
    }

    public static func maxAttempts(_ value: Int, alreadyAttempted: Int = 0) throws -> Int {
        guard (1...maximumAttempts).contains(value), value >= alreadyAttempted else { throw TaskStoreError.invalidMaxAttempts }
        return value
    }
}

public struct TaskStateMachine: Sendable {
    public init() {}

    public func validateTransition(from record: TaskRecord, to newState: TaskState, now: Date = Date()) throws {
        guard record.state != newState else { throw TaskStoreError.invalidTransition(from: record.state, to: newState) }

        let allowed: Set<TaskState>
        switch record.state {
        case .draft: allowed = [.ready, .cancelled]
        case .ready: allowed = [.running, .cancelled]
        case .running: allowed = [.waitingForPermission, .succeeded, .failed, .cancelled, .interrupted]
        case .waitingForPermission: allowed = [.running, .failed, .cancelled, .interrupted]
        case .interrupted: allowed = [.ready, .cancelled]
        case .failed: allowed = [.ready, .cancelled]
        case .succeeded, .cancelled: allowed = []
        }
        guard allowed.contains(newState) else { throw TaskStoreError.invalidTransition(from: record.state, to: newState) }

        if newState == .running, record.state == .ready {
            if record.attemptCount >= record.maxAttempts { throw TaskStoreError.maxAttemptsReached(record.maxAttempts) }
            if let eligible = record.nextEligibleAt, eligible > now { throw TaskStoreError.notYetEligible(eligible) }
        }
        if newState == .ready, (record.state == .failed || record.state == .interrupted), record.attemptCount >= record.maxAttempts {
            throw TaskStoreError.maxAttemptsReached(record.maxAttempts)
        }
    }

    public func resultingAttemptCount(from record: TaskRecord, to newState: TaskState) -> Int {
        record.state == .ready && newState == .running ? record.attemptCount + 1 : record.attemptCount
    }
}

public enum TaskStoreError: Error, CustomStringConvertible, Sendable, Equatable {
    case openFailed(String)
    case statementFailed(String)
    case executionFailed(String)
    case corruptData(String)
    case notFound(TaskID)
    case revisionConflict(taskID: TaskID, expected: Int, actual: Int?)
    case invalidTransition(from: TaskState, to: TaskState)
    case notEditable(TaskState)
    case notYetEligible(Date)
    case invalidTitle
    case invalidInstruction
    case invalidMaxAttempts
    case detailTooLong
    case maxAttemptsReached(Int)

    public var description: String {
        switch self {
        case .openFailed(let detail): return "Task store open failed: \(detail)"
        case .statementFailed(let detail): return "Task store statement failed: \(detail)"
        case .executionFailed(let detail): return "Task store execution failed: \(detail)"
        case .corruptData(let detail): return "Task store contains corrupt data: \(detail)"
        case .notFound(let id): return "Task \(id.description) was not found."
        case .revisionConflict(let id, let expected, let actual): return "Task \(id.description) revision conflict: expected \(expected), actual \(actual.map(String.init) ?? "none")."
        case .invalidTransition(let from, let to): return "Illegal task transition \(from.rawValue) → \(to.rawValue)."
        case .notEditable(let state): return "Task cannot be edited while state is \(state.rawValue)."
        case .notYetEligible(let date): return "Task is not eligible to run before \(date)."
        case .invalidTitle: return "Task title must contain 1...\(TaskValidation.maximumTitleCharacters) characters."
        case .invalidInstruction: return "Task instruction must contain 1...\(TaskValidation.maximumInstructionCharacters) characters."
        case .invalidMaxAttempts: return "Task maxAttempts must be 1...\(TaskValidation.maximumAttempts) and not below attempts already used."
        case .detailTooLong: return "Task error/result/reason detail exceeds \(TaskValidation.maximumDetailCharacters) characters."
        case .maxAttemptsReached(let limit): return "Task attempt limit reached (\(limit))."
        }
    }
}
