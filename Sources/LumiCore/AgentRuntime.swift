import Foundation

public actor AgentRuntime {
    private let planner: any AgentPlanning
    private let tools: ToolRuntime
    private let store: any AgentRunStoring

    public init(
        planner: any AgentPlanning,
        tools: ToolRuntime,
        store: any AgentRunStoring = InMemoryAgentRunStore()
    ) {
        self.planner = planner
        self.tools = tools
        self.store = store
    }

    public func start(
        goal: String,
        classification: RequestClassification? = nil,
        budget: AgentBudget = AgentBudget()
    ) async throws -> AgentRun {
        let cleanGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGoal.isEmpty else { throw AgentRuntimeError.emptyGoal }

        var run = AgentRun(
            goal: cleanGoal,
            classification: classification,
            state: .created,
            budget: budget
        )
        try await persist(run)

        run = run.replacing(state: .planning)
        try await persist(run)
        return try await advance(run)
    }

    public func resume(
        runID: UUID,
        confirmation: ToolConfirmation
    ) async throws -> AgentRun {
        guard var run = try await store.load(id: runID) else {
            throw AgentRuntimeError.runNotFound
        }
        guard run.state == .waitingForConfirmation, let pending = run.pendingCall else {
            throw AgentRuntimeError.invalidState("Run is not waiting for a tool confirmation.")
        }
        guard confirmation.callID == pending.id else {
            throw AgentRuntimeError.confirmationMismatch
        }
        guard let lastIndex = run.steps.lastIndex(where: { $0.call.id == pending.id }) else {
            throw AgentRuntimeError.invalidState("Pending call has no checkpointed agent step.")
        }

        run = run.replacing(state: .executing)
        try await persist(run)

        let result = await tools.execute(pending, confirmation: confirmation)
        var steps = run.steps
        steps[lastIndex] = steps[lastIndex].replacing(result: result)
        run = run.replacing(
            state: stateAfterToolResult(result),
            steps: steps,
            pendingCall: .some(result.status == .confirmationRequired ? pending : nil)
        )
        try await persist(run)

        if result.status == .confirmationRequired {
            return run
        }
        if result.status == .cancelled {
            return run.replacing(state: .cancelled)
        }

        run = run.replacing(state: .replanning, pendingCall: .some(nil))
        try await persist(run)
        return try await advance(run)
    }

    public func load(runID: UUID) async throws -> AgentRun? {
        try await store.load(id: runID)
    }

    public func recentRuns(limit: Int = 20) async throws -> [AgentRun] {
        try await store.recent(limit: limit)
    }

    public func cancel(runID: UUID) async throws -> AgentRun {
        guard let run = try await store.load(id: runID) else {
            throw AgentRuntimeError.runNotFound
        }
        let cancelled = run.replacing(
            state: .cancelled,
            pendingCall: .some(nil),
            error: .some(nil)
        )
        try await persist(cancelled)
        return cancelled
    }

    private func advance(_ initialRun: AgentRun) async throws -> AgentRun {
        var run = initialRun
        let activeCycleStartedAt = Date()

        while true {
            if Task.isCancelled {
                let cancelled = run.replacing(state: .cancelled, pendingCall: .some(nil))
                try? await persist(cancelled)
                return cancelled
            }

            if Date().timeIntervalSince(activeCycleStartedAt) >= Double(run.budget.maxDurationSeconds) {
                let exceeded = run.replacing(
                    state: .budgetExceeded,
                    pendingCall: .some(nil),
                    error: .some("Agent active-duration budget exceeded.")
                )
                try await persist(exceeded)
                return exceeded
            }

            if run.steps.count >= run.budget.maxSteps || run.toolCallCount >= run.budget.maxToolCalls {
                let exceeded = run.replacing(
                    state: .budgetExceeded,
                    pendingCall: .some(nil),
                    error: .some("Agent step/tool-call budget exceeded.")
                )
                try await persist(exceeded)
                return exceeded
            }

            let planningState: AgentRunState = run.steps.isEmpty ? .planning : .replanning
            run = run.replacing(state: planningState, pendingCall: .some(nil))
            try await persist(run)

            let toolsAvailable = await tools.availableTools()
            let decision: AgentDecision
            do {
                decision = try await planner.decide(
                    AgentPlanningContext(run: run, availableTools: toolsAvailable)
                )
            } catch is CancellationError {
                let cancelled = run.replacing(state: .cancelled, pendingCall: .some(nil))
                try? await persist(cancelled)
                return cancelled
            } catch {
                let failed = run.replacing(
                    state: .failed,
                    pendingCall: .some(nil),
                    error: .some(error.localizedDescription)
                )
                try await persist(failed)
                return failed
            }

            switch decision {
            case .finish(let answer):
                let cleanAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanAnswer.isEmpty else {
                    let failed = run.replacing(
                        state: .failed,
                        error: .some("Planner returned an empty final answer.")
                    )
                    try await persist(failed)
                    return failed
                }

                let completed = run.replacing(
                    state: .completed,
                    pendingCall: .some(nil),
                    finalAnswer: .some(cleanAnswer),
                    error: .some(nil)
                )
                try await persist(completed)
                return completed

            case .tool(let name, let arguments, let note):
                if run.toolCallCount >= run.budget.maxToolCalls {
                    let exceeded = run.replacing(
                        state: .budgetExceeded,
                        error: .some("Agent tool-call budget exceeded.")
                    )
                    try await persist(exceeded)
                    return exceeded
                }

                let call = ToolCall(
                    toolName: name,
                    arguments: arguments.mapValues(\.toolValue),
                    origin: .agent
                )
                let startedAt = Date()
                run = run.replacing(state: .executing, pendingCall: .some(call))
                try await persist(run)

                let result = await tools.execute(call)
                let step = AgentStep(
                    index: run.steps.count + 1,
                    call: call,
                    note: note,
                    result: result,
                    startedAt: startedAt
                )
                let steps = run.steps + [step]

                if result.status == .confirmationRequired {
                    let waiting = run.replacing(
                        state: .waitingForConfirmation,
                        steps: steps,
                        pendingCall: .some(call),
                        error: .some(nil)
                    )
                    try await persist(waiting)
                    return waiting
                }

                if result.status == .cancelled {
                    let cancelled = run.replacing(
                        state: .cancelled,
                        steps: steps,
                        pendingCall: .some(nil)
                    )
                    try await persist(cancelled)
                    return cancelled
                }

                run = run.replacing(
                    state: .observing,
                    steps: steps,
                    pendingCall: .some(nil),
                    error: .some(nil)
                )
                try await persist(run)
            }
        }
    }

    private func stateAfterToolResult(_ result: ToolResult) -> AgentRunState {
        switch result.status {
        case .confirmationRequired: return .waitingForConfirmation
        case .cancelled: return .cancelled
        case .success, .denied, .failed, .timeout: return .observing
        }
    }

    private func persist(_ run: AgentRun) async throws {
        do {
            try await store.save(run)
        } catch {
            throw AgentRuntimeError.persistenceFailed(error.localizedDescription)
        }
    }
}

public actor InMemoryAgentRunStore: AgentRunStoring {
    private var runs: [UUID: AgentRun] = [:]

    public init() {}

    public func save(_ run: AgentRun) {
        runs[run.id] = run
    }

    public func load(id: UUID) -> AgentRun? {
        runs[id]
    }

    public func recent(limit: Int) -> [AgentRun] {
        runs.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(max(0, limit))
            .map { $0 }
    }
}
