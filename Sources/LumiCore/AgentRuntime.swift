import Foundation

public actor AgentRuntime {
    private typealias EventSink = @Sendable (AgentEvent) -> Void

    private let planner: any AgentPlanning
    private let tools: ToolRuntime
    private let store: any AgentRunStoring
    private var eventSubscribers: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]

    public init(
        planner: any AgentPlanning,
        tools: ToolRuntime,
        store: any AgentRunStoring = InMemoryAgentRunStore()
    ) {
        self.planner = planner
        self.tools = tools
        self.store = store
    }

    /// Observes operational events from runs executed by this runtime, including runs started
    /// through LumiEngine. The bounded buffer avoids an unbounded UI/diagnostics backlog.
    public func events(bufferingNewest limit: Int = 128) -> AsyncStream<AgentEvent> {
        let subscriberID = UUID()
        let pair = AsyncStream<AgentEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(max(8, min(limit, 1_024)))
        )
        eventSubscribers[subscriberID] = pair.continuation
        pair.continuation.onTermination = { @Sendable _ in
            Task {
                await self.removeEventSubscriber(subscriberID)
            }
        }
        return pair.stream
    }

    public func start(
        goal: String,
        classification: RequestClassification? = nil,
        budget: AgentBudget = AgentBudget()
    ) async throws -> AgentRun {
        try await startInternal(
            goal: goal,
            classification: classification,
            budget: budget,
            eventSink: nil
        )
    }

    public func streamStart(
        goal: String,
        classification: RequestClassification? = nil,
        budget: AgentBudget = AgentBudget()
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await self.startInternal(
                        goal: goal,
                        classification: classification,
                        budget: budget,
                        eventSink: { event in
                            continuation.yield(event)
                        }
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    public func resume(
        runID: UUID,
        confirmation: ToolConfirmation
    ) async throws -> AgentRun {
        try await resumeInternal(
            runID: runID,
            confirmation: confirmation,
            eventSink: nil
        )
    }

    public func streamResume(
        runID: UUID,
        confirmation: ToolConfirmation
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await self.resumeInternal(
                        runID: runID,
                        confirmation: confirmation,
                        eventSink: { event in
                            continuation.yield(event)
                        }
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
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
        try await persist(cancelled, eventSink: nil)
        return cancelled
    }

    private func startInternal(
        goal: String,
        classification: RequestClassification?,
        budget: AgentBudget,
        eventSink: EventSink?
    ) async throws -> AgentRun {
        let cleanGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGoal.isEmpty else { throw AgentRuntimeError.emptyGoal }

        var run = AgentRun(
            goal: cleanGoal,
            classification: classification,
            state: .created,
            budget: budget
        )
        try await persist(run, eventSink: eventSink)

        run = run.replacing(state: .planning)
        try await persist(run, eventSink: eventSink)
        return try await advance(run, eventSink: eventSink)
    }

    private func resumeInternal(
        runID: UUID,
        confirmation: ToolConfirmation,
        eventSink: EventSink?
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

        emit(.runUpdated(run), eventSink: eventSink)

        run = run.replacing(state: .executing)
        try await persist(run, eventSink: eventSink)
        emit(.toolStarted(runID: run.id, call: pending), eventSink: eventSink)

        let result = await tools.execute(pending, confirmation: confirmation)
        emit(.toolFinished(runID: run.id, result: result), eventSink: eventSink)

        var steps = run.steps
        steps[lastIndex] = steps[lastIndex].replacing(result: result)
        run = run.replacing(
            state: stateAfterToolResult(result),
            steps: steps,
            pendingCall: .some(result.status == .confirmationRequired ? pending : nil)
        )
        try await persist(run, eventSink: eventSink)

        if result.status == .confirmationRequired {
            emit(.confirmationRequired(runID: run.id, call: pending), eventSink: eventSink)
            return run
        }
        if result.status == .cancelled {
            let cancelled = run.replacing(state: .cancelled, pendingCall: .some(nil))
            try await persist(cancelled, eventSink: eventSink)
            return cancelled
        }

        run = run.replacing(state: .replanning, pendingCall: .some(nil))
        try await persist(run, eventSink: eventSink)
        return try await advance(run, eventSink: eventSink)
    }

    private func advance(
        _ initialRun: AgentRun,
        eventSink: EventSink?
    ) async throws -> AgentRun {
        var run = initialRun
        let activeCycleStartedAt = Date()

        while true {
            if Task.isCancelled {
                let cancelled = run.replacing(state: .cancelled, pendingCall: .some(nil))
                try? await persist(cancelled, eventSink: eventSink)
                return cancelled
            }

            if Date().timeIntervalSince(activeCycleStartedAt) >= Double(run.budget.maxDurationSeconds) {
                let exceeded = run.replacing(
                    state: .budgetExceeded,
                    pendingCall: .some(nil),
                    error: .some("Agent active-duration budget exceeded.")
                )
                try await persist(exceeded, eventSink: eventSink)
                return exceeded
            }

            // Always allow one more planning turn after the final permitted observation so the
            // planner can synthesize a final answer. Budgets are enforced only if it asks for
            // another tool call.
            let planningState: AgentRunState = run.steps.isEmpty ? .planning : .replanning
            run = run.replacing(state: planningState, pendingCall: .some(nil))
            try await persist(run, eventSink: eventSink)

            let toolsAvailable = await tools.availableTools()
            let decision: AgentDecision
            do {
                decision = try await planner.decide(
                    AgentPlanningContext(run: run, availableTools: toolsAvailable)
                )
            } catch is CancellationError {
                let cancelled = run.replacing(state: .cancelled, pendingCall: .some(nil))
                try? await persist(cancelled, eventSink: eventSink)
                return cancelled
            } catch {
                let failed = run.replacing(
                    state: .failed,
                    pendingCall: .some(nil),
                    error: .some(error.localizedDescription)
                )
                try await persist(failed, eventSink: eventSink)
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
                    try await persist(failed, eventSink: eventSink)
                    return failed
                }

                let completed = run.replacing(
                    state: .completed,
                    pendingCall: .some(nil),
                    finalAnswer: .some(cleanAnswer),
                    error: .some(nil)
                )
                try await persist(completed, eventSink: eventSink)
                return completed

            case .tool(let name, let arguments, let note):
                guard run.steps.count < run.budget.maxSteps,
                      run.toolCallCount < run.budget.maxToolCalls else {
                    let exceeded = run.replacing(
                        state: .budgetExceeded,
                        pendingCall: .some(nil),
                        error: .some("Agent step/tool-call budget exceeded before another tool execution.")
                    )
                    try await persist(exceeded, eventSink: eventSink)
                    return exceeded
                }

                let call = ToolCall(
                    toolName: name,
                    arguments: arguments.mapValues { $0.toolValue },
                    origin: .agent
                )
                let startedAt = Date()
                run = run.replacing(state: .executing, pendingCall: .some(call))
                try await persist(run, eventSink: eventSink)
                emit(.toolStarted(runID: run.id, call: call), eventSink: eventSink)

                let result = await tools.execute(call)
                emit(.toolFinished(runID: run.id, result: result), eventSink: eventSink)

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
                    try await persist(waiting, eventSink: eventSink)
                    emit(.confirmationRequired(runID: waiting.id, call: call), eventSink: eventSink)
                    return waiting
                }

                if result.status == .cancelled {
                    let cancelled = run.replacing(
                        state: .cancelled,
                        steps: steps,
                        pendingCall: .some(nil)
                    )
                    try await persist(cancelled, eventSink: eventSink)
                    return cancelled
                }

                run = run.replacing(
                    state: .observing,
                    steps: steps,
                    pendingCall: .some(nil),
                    error: .some(nil)
                )
                try await persist(run, eventSink: eventSink)
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

    private func persist(
        _ run: AgentRun,
        eventSink: EventSink?
    ) async throws {
        do {
            try await store.save(run)
        } catch {
            throw AgentRuntimeError.persistenceFailed(error.localizedDescription)
        }

        emit(.runUpdated(run), eventSink: eventSink)
        if isTerminal(run.state) {
            emit(.terminal(run), eventSink: eventSink)
        }
    }

    private func emit(_ event: AgentEvent, eventSink: EventSink?) {
        eventSink?(event)
        for continuation in eventSubscribers.values {
            continuation.yield(event)
        }
    }

    private func removeEventSubscriber(_ id: UUID) {
        eventSubscribers.removeValue(forKey: id)
    }

    private func isTerminal(_ state: AgentRunState) -> Bool {
        switch state {
        case .completed, .failed, .cancelled, .budgetExceeded:
            return true
        case .created, .planning, .executing, .waitingForConfirmation, .observing, .replanning:
            return false
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
