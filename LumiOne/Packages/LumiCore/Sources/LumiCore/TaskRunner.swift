import Foundation

public enum TaskRunOutcome: Sendable {
    case completed(task: TaskRecord, response: RuntimeResponse)
    case permissionRequired(task: TaskRecord, approval: PendingToolApproval)
    case failed(task: TaskRecord, message: String)
    case cancelled(task: TaskRecord)
}

/// Manual, single-task execution wrapper around the existing AgentRuntime.
/// TaskRunner does not plan, call tools or grant permissions itself. It only
/// persists a truthful task lifecycle around AgentRuntime outcomes.
public actor TaskRunner {
    private let tasks: TaskService
    private let runtime: AgentRuntime
    private var active: ActiveTaskRun?

    public init(tasks: TaskService, runtime: AgentRuntime) {
        self.tasks = tasks
        self.runtime = runtime
    }

    public func activeTaskID() async throws -> TaskID? {
        try await normalizeInactiveTerminalSession()
        return active?.taskID
    }

    public func start(
        taskID: TaskID,
        expectedRevision: Int
    ) async throws -> TaskRunOutcome {
        try await ensureRunnerAvailable(for: taskID)
        guard let current = try await tasks.load(id: taskID) else {
            throw TaskRunnerError.taskNotFound(taskID)
        }
        try Self.validateRevision(current, expected: expectedRevision)
        guard current.state == .ready else {
            throw TaskRunnerError.cannotStart(current.state)
        }
        return try await startReadyTask(current)
    }

    /// Resume is deliberately explicit. Failed/interrupted work is first moved
    /// back to `ready` by a user-attributed transition, then a new attempt starts.
    public func resume(
        taskID: TaskID,
        expectedRevision: Int
    ) async throws -> TaskRunOutcome {
        try await ensureRunnerAvailable(for: taskID)
        guard let current = try await tasks.load(id: taskID) else {
            throw TaskRunnerError.taskNotFound(taskID)
        }
        try Self.validateRevision(current, expected: expectedRevision)
        guard current.state == .failed || current.state == .interrupted else {
            throw TaskRunnerError.cannotResume(current.state)
        }

        let ready = try await tasks.transition(
            id: current.id,
            to: .ready,
            expectedRevision: current.revision,
            actor: .user,
            reason: "Explicit manual task resume"
        )
        return try await startReadyTask(ready)
    }

    public func approvePermission(
        taskID: TaskID,
        pendingID: UUID,
        duration: GrantDuration
    ) async throws -> TaskRunOutcome {
        let session = try await requirePendingSession(taskID: taskID, pendingID: pendingID)
        guard let current = try await tasks.load(id: taskID) else {
            active = nil
            throw TaskRunnerError.taskNotFound(taskID)
        }
        if current.state == .cancelled {
            active = nil
            return .cancelled(task: current)
        }
        guard current.state == .waitingForPermission else {
            throw TaskRunnerError.stateChanged(
                taskID: taskID,
                expected: .waitingForPermission,
                actual: current.state
            )
        }

        do {
            let runtimeOutcome = try await runtime.approvePermission(
                pendingID: pendingID,
                duration: duration
            )
            return try await handlePermissionContinuation(
                runtimeOutcome,
                session: session,
                waitingTaskRevision: current.revision,
                denial: false
            )
        } catch {
            return try await failIfStillActive(
                taskID: taskID,
                expectedStates: [.waitingForPermission, .running],
                message: "Task runtime failed after permission approval: \(error)"
            )
        }
    }

    public func denyPermission(
        taskID: TaskID,
        pendingID: UUID
    ) async throws -> TaskRunOutcome {
        let session = try await requirePendingSession(taskID: taskID, pendingID: pendingID)
        guard let current = try await tasks.load(id: taskID) else {
            active = nil
            throw TaskRunnerError.taskNotFound(taskID)
        }
        if current.state == .cancelled {
            active = nil
            return .cancelled(task: current)
        }
        guard current.state == .waitingForPermission else {
            throw TaskRunnerError.stateChanged(
                taskID: taskID,
                expected: .waitingForPermission,
                actual: current.state
            )
        }

        do {
            let runtimeOutcome = try await runtime.denyPermission(pendingID: pendingID)
            return try await handlePermissionContinuation(
                runtimeOutcome,
                session: session,
                waitingTaskRevision: current.revision,
                denial: true
            )
        } catch {
            return try await failIfStillActive(
                taskID: taskID,
                expectedStates: [.waitingForPermission],
                message: "Task runtime failed after permission denial: \(error)"
            )
        }
    }

    private func startReadyTask(_ ready: TaskRecord) async throws -> TaskRunOutcome {
        let running = try await tasks.transition(
            id: ready.id,
            to: .running,
            expectedRevision: ready.revision,
            actor: .runner,
            reason: "Manual TaskRunner start"
        )
        let session = ActiveTaskRun(
            taskID: running.id,
            conversationID: UUID(),
            pendingApprovalID: nil
        )
        active = session

        do {
            let outcome = try await runtime.send(
                running.instruction,
                conversationID: session.conversationID,
                title: "Task: \(running.title)"
            )
            return try await handleInitialRuntimeOutcome(
                outcome,
                session: session,
                runningTaskRevision: running.revision
            )
        } catch {
            return try await failIfStillActive(
                taskID: running.id,
                expectedStates: [.running],
                message: "Task runtime failed: \(error)"
            )
        }
    }

    private func handleInitialRuntimeOutcome(
        _ outcome: RuntimeOutcome,
        session: ActiveTaskRun,
        runningTaskRevision: Int
    ) async throws -> TaskRunOutcome {
        guard let current = try await tasks.load(id: session.taskID) else {
            active = nil
            throw TaskRunnerError.taskNotFound(session.taskID)
        }
        if current.state == .cancelled {
            active = nil
            return .cancelled(task: current)
        }
        guard current.state == .running, current.revision == runningTaskRevision else {
            throw TaskRunnerError.stateChanged(
                taskID: current.id,
                expected: .running,
                actual: current.state
            )
        }

        switch outcome {
        case .completed(let response):
            let completed = try await tasks.transition(
                id: current.id,
                to: .succeeded,
                expectedRevision: current.revision,
                actor: .runner,
                reason: "AgentRuntime completed task",
                resultSummary: Self.boundedDetail(response.assistantMessage.content)
            )
            active = nil
            return .completed(task: completed, response: response)

        case .permissionRequired(let approval):
            let waiting = try await tasks.transition(
                id: current.id,
                to: .waitingForPermission,
                expectedRevision: current.revision,
                actor: .runner,
                reason: "Protected tool requires explicit user permission"
            )
            active = ActiveTaskRun(
                taskID: session.taskID,
                conversationID: session.conversationID,
                pendingApprovalID: approval.id
            )
            return .permissionRequired(task: waiting, approval: approval)
        }
    }

    private func handlePermissionContinuation(
        _ outcome: RuntimeOutcome,
        session: ActiveTaskRun,
        waitingTaskRevision: Int,
        denial: Bool
    ) async throws -> TaskRunOutcome {
        guard let current = try await tasks.load(id: session.taskID) else {
            active = nil
            throw TaskRunnerError.taskNotFound(session.taskID)
        }
        if current.state == .cancelled {
            active = nil
            return .cancelled(task: current)
        }
        guard current.state == .waitingForPermission,
              current.revision == waitingTaskRevision else {
            throw TaskRunnerError.stateChanged(
                taskID: current.id,
                expected: .waitingForPermission,
                actual: current.state
            )
        }

        switch outcome {
        case .permissionRequired(let approval):
            // AgentRuntime may legitimately request another exact capability
            // after the previous decision. The task remains visibly waiting;
            // no extra attempt is consumed and nothing is auto-approved.
            active = ActiveTaskRun(
                taskID: session.taskID,
                conversationID: session.conversationID,
                pendingApprovalID: approval.id
            )
            return .permissionRequired(task: current, approval: approval)

        case .completed(let response):
            if denial {
                let failed = try await tasks.transition(
                    id: current.id,
                    to: .failed,
                    expectedRevision: current.revision,
                    actor: .runner,
                    reason: "Required permission denied by user",
                    lastError: "Required permission denied by user",
                    resultSummary: Self.boundedDetail(response.assistantMessage.content)
                )
                active = nil
                return .failed(
                    task: failed,
                    message: "Required permission denied by user"
                )
            }

            let resumed = try await tasks.transition(
                id: current.id,
                to: .running,
                expectedRevision: current.revision,
                actor: .runner,
                reason: "Permission approved; AgentRuntime resumed"
            )
            let completed = try await tasks.transition(
                id: resumed.id,
                to: .succeeded,
                expectedRevision: resumed.revision,
                actor: .runner,
                reason: "AgentRuntime completed task",
                resultSummary: Self.boundedDetail(response.assistantMessage.content)
            )
            active = nil
            return .completed(task: completed, response: response)
        }
    }

    private func failIfStillActive(
        taskID: TaskID,
        expectedStates: Set<TaskState>,
        message: String
    ) async throws -> TaskRunOutcome {
        let bounded = Self.boundedDetail(message)
        guard let current = try await tasks.load(id: taskID) else {
            active = nil
            throw TaskRunnerError.taskNotFound(taskID)
        }
        if current.state == .cancelled {
            active = nil
            return .cancelled(task: current)
        }
        guard expectedStates.contains(current.state) else {
            active = nil
            throw TaskRunnerError.stateChanged(
                taskID: taskID,
                expected: expectedStates.sorted { $0.rawValue < $1.rawValue }.first ?? current.state,
                actual: current.state
            )
        }
        let failed = try await tasks.transition(
            id: current.id,
            to: .failed,
            expectedRevision: current.revision,
            actor: .runner,
            reason: bounded,
            lastError: bounded
        )
        active = nil
        return .failed(task: failed, message: bounded)
    }

    private func ensureRunnerAvailable(for requestedTaskID: TaskID) async throws {
        try await normalizeInactiveTerminalSession()
        if let active {
            throw TaskRunnerError.busy(activeTaskID: active.taskID, requestedTaskID: requestedTaskID)
        }
    }

    private func requirePendingSession(
        taskID: TaskID,
        pendingID: UUID
    ) async throws -> ActiveTaskRun {
        try await normalizeInactiveTerminalSession()
        guard let active else {
            throw TaskRunnerError.noActiveRun
        }
        guard active.taskID == taskID else {
            throw TaskRunnerError.activeTaskMismatch(
                expected: active.taskID,
                actual: taskID
            )
        }
        guard active.pendingApprovalID == pendingID else {
            throw TaskRunnerError.pendingApprovalMismatch
        }
        return active
    }

    /// Direct UI cancellation may occur outside TaskRunner through TaskService.
    /// Normalize that state before accepting new work so a cancelled task cannot
    /// keep the single-runner slot forever.
    private func normalizeInactiveTerminalSession() async throws {
        guard let active else { return }
        guard let current = try await tasks.load(id: active.taskID) else {
            self.active = nil
            return
        }
        switch current.state {
        case .cancelled, .succeeded, .failed, .interrupted:
            self.active = nil
        case .draft, .ready, .running, .waitingForPermission:
            break
        }
    }

    private static func validateRevision(_ record: TaskRecord, expected: Int) throws {
        guard record.revision == expected else {
            throw TaskStoreError.revisionConflict(
                taskID: record.id,
                expected: expected,
                actual: record.revision
            )
        }
    }

    private static func boundedDetail(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > TaskValidation.maximumDetailCharacters else {
            return normalized
        }
        return String(normalized.prefix(TaskValidation.maximumDetailCharacters))
    }
}

private struct ActiveTaskRun: Sendable {
    let taskID: TaskID
    let conversationID: UUID
    let pendingApprovalID: UUID?
}

public enum TaskRunnerError: Error, CustomStringConvertible, Sendable, Equatable {
    case taskNotFound(TaskID)
    case busy(activeTaskID: TaskID, requestedTaskID: TaskID)
    case cannotStart(TaskState)
    case cannotResume(TaskState)
    case noActiveRun
    case activeTaskMismatch(expected: TaskID, actual: TaskID)
    case pendingApprovalMismatch
    case stateChanged(taskID: TaskID, expected: TaskState, actual: TaskState)

    public var description: String {
        switch self {
        case .taskNotFound(let id):
            return "Task \(id.description) was not found."
        case .busy(let active, let requested):
            return "TaskRunner is already handling \(active.description); cannot start \(requested.description)."
        case .cannotStart(let state):
            return "TaskRunner can start only a ready task; current state is \(state.rawValue)."
        case .cannotResume(let state):
            return "TaskRunner can resume only failed or interrupted work; current state is \(state.rawValue)."
        case .noActiveRun:
            return "TaskRunner has no active task run."
        case .activeTaskMismatch(let expected, let actual):
            return "Active TaskRunner task is \(expected.description), not \(actual.description)."
        case .pendingApprovalMismatch:
            return "TaskRunner permission decision does not match the active pending approval."
        case .stateChanged(let taskID, let expected, let actual):
            return "Task \(taskID.description) changed state while running: expected \(expected.rawValue), actual \(actual.rawValue)."
        }
    }
}
