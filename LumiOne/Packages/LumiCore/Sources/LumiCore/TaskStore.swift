import Foundation

public protocol TaskStore: Sendable {
    func create(_ request: TaskCreateRequest) async throws -> TaskRecord
    func load(id: TaskID) async throws -> TaskRecord?
    func list(limit: Int) async throws -> [TaskRecord]
    func events(taskID: TaskID, limit: Int) async throws -> [TaskEvent]
    func edit(_ request: TaskEditRequest) async throws -> TaskRecord
    func transition(_ request: TaskTransitionRequest) async throws -> TaskRecord
    /// Converts non-terminal in-flight tasks left by a previous process into an
    /// explicit interrupted state. Recovery never resumes execution by itself.
    func recoverInterruptedTasks() async throws -> [TaskRecord]
}

public final class TaskService: @unchecked Sendable {
    private let store: any TaskStore

    public init(store: any TaskStore) {
        self.store = store
    }

    public func create(
        title: String,
        instruction: String,
        maxAttempts: Int = 3,
        nextEligibleAt: Date? = nil,
        origin: TaskOrigin = TaskOrigin(),
        actor: TaskMutationActor
    ) async throws -> TaskRecord {
        try await store.create(
            TaskCreateRequest(
                title: title,
                instruction: instruction,
                maxAttempts: maxAttempts,
                nextEligibleAt: nextEligibleAt,
                origin: origin,
                actor: actor
            )
        )
    }

    public func load(id: TaskID) async throws -> TaskRecord? {
        try await store.load(id: id)
    }

    public func list(limit: Int = 100) async throws -> [TaskRecord] {
        guard (1...500).contains(limit) else {
            throw TaskStoreError.executionFailed("task list limit must be 1...500")
        }
        return try await store.list(limit: limit)
    }

    public func events(taskID: TaskID, limit: Int = 200) async throws -> [TaskEvent] {
        guard (1...1_000).contains(limit) else {
            throw TaskStoreError.executionFailed("task event limit must be 1...1000")
        }
        return try await store.events(taskID: taskID, limit: limit)
    }

    public func edit(
        id: TaskID,
        title: String,
        instruction: String,
        maxAttempts: Int,
        nextEligibleAt: Date?,
        expectedRevision: Int,
        actor: TaskMutationActor,
        reason: String? = nil
    ) async throws -> TaskRecord {
        try await store.edit(
            TaskEditRequest(
                id: id,
                title: title,
                instruction: instruction,
                maxAttempts: maxAttempts,
                nextEligibleAt: nextEligibleAt,
                expectedRevision: expectedRevision,
                actor: actor,
                reason: reason
            )
        )
    }

    public func transition(
        id: TaskID,
        to state: TaskState,
        expectedRevision: Int,
        actor: TaskMutationActor,
        reason: String? = nil,
        lastError: String? = nil,
        resultSummary: String? = nil
    ) async throws -> TaskRecord {
        try await store.transition(
            TaskTransitionRequest(
                id: id,
                toState: state,
                expectedRevision: expectedRevision,
                actor: actor,
                reason: reason,
                lastError: lastError,
                resultSummary: resultSummary
            )
        )
    }

    public func cancel(
        id: TaskID,
        expectedRevision: Int,
        actor: TaskMutationActor = .user,
        reason: String? = "Cancelled by user"
    ) async throws -> TaskRecord {
        try await transition(
            id: id,
            to: .cancelled,
            expectedRevision: expectedRevision,
            actor: actor,
            reason: reason
        )
    }

    public func recoverInterruptedTasks() async throws -> [TaskRecord] {
        try await store.recoverInterruptedTasks()
    }
}
