import XCTest
@testable import LumiCore

final class AgentEventTests: XCTestCase {
    func testStreamStartEmitsStateAndToolLifecycleUntilCompletion() async throws {
        let runtime = AgentRuntime(
            planner: EventSequencePlanner(),
            tools: ToolRuntime(
                registry: ToolRegistry(tools: [EventEchoTool()])
            )
        )

        let stream = await runtime.streamStart(goal: "Read one value and finish")
        var events: [AgentEvent] = []
        for try await event in stream {
            events.append(event)
        }

        let states = events.compactMap { event -> AgentRunState? in
            guard case .runUpdated(let run) = event else { return nil }
            return run.state
        }

        XCTAssertTrue(states.contains(.created))
        XCTAssertTrue(states.contains(.planning))
        XCTAssertTrue(states.contains(.executing))
        XCTAssertTrue(states.contains(.observing))
        XCTAssertTrue(states.contains(.replanning))
        XCTAssertTrue(states.contains(.completed))

        XCTAssertTrue(events.contains { event in
            if case .toolStarted(_, let call) = event {
                return call.toolName == "event.echo"
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .toolFinished(_, let result) = event {
                return result.toolName == "event.echo" && result.status == .success
            }
            return false
        })

        guard case .terminal(let finalRun)? = events.last else {
            return XCTFail("Expected a terminal event at the end of the stream.")
        }
        XCTAssertEqual(finalRun.state, .completed)
        XCTAssertEqual(finalRun.finalAnswer, "Observed the tool result.")
        XCTAssertEqual(finalRun.steps.count, 1)
    }

    func testConfirmationPauseAndResumeHaveSeparateLiveStreams() async throws {
        let recorder = EventExecutionRecorder()
        let runtime = AgentRuntime(
            planner: ConfirmationEventPlanner(),
            tools: ToolRuntime(
                registry: ToolRegistry(tools: [EventConfirmedTool(recorder: recorder)])
            )
        )

        let startStream = await runtime.streamStart(goal: "Use the confirmed read tool")
        var startEvents: [AgentEvent] = []
        for try await event in startStream {
            startEvents.append(event)
        }

        guard let waitingRun = startEvents.compactMap({ event -> AgentRun? in
            if case .runUpdated(let run) = event, run.state == .waitingForConfirmation {
                return run
            }
            return nil
        }).last,
        let pending = waitingRun.pendingCall else {
            return XCTFail("Expected a persisted waiting-for-confirmation checkpoint.")
        }

        XCTAssertTrue(startEvents.contains { event in
            if case .confirmationRequired(let runID, let call) = event {
                return runID == waitingRun.id && call.id == pending.id
            }
            return false
        })
        let executedBeforeApproval = await recorder.count()
        XCTAssertEqual(executedBeforeApproval, 0)
        XCTAssertFalse(startEvents.contains { event in
            if case .terminal = event { return true }
            return false
        })

        let resumeStream = await runtime.streamResume(
            runID: waitingRun.id,
            confirmation: ToolConfirmation(callID: pending.id, approved: true)
        )
        var resumeEvents: [AgentEvent] = []
        for try await event in resumeStream {
            resumeEvents.append(event)
        }

        XCTAssertTrue(resumeEvents.contains { event in
            if case .toolStarted(let runID, let call) = event {
                return runID == waitingRun.id && call.id == pending.id
            }
            return false
        })
        XCTAssertTrue(resumeEvents.contains { event in
            if case .toolFinished(let runID, let result) = event {
                return runID == waitingRun.id
                    && result.callID == pending.id
                    && result.status == .success
            }
            return false
        })

        let executedAfterApproval = await recorder.count()
        XCTAssertEqual(executedAfterApproval, 1)

        guard case .terminal(let finalRun)? = resumeEvents.last else {
            return XCTFail("Expected completion after approved resume.")
        }
        XCTAssertEqual(finalRun.state, .completed)
        XCTAssertEqual(finalRun.finalAnswer, "Confirmed observation complete.")
    }

    func testRejectResumeStreamsDeniedObservationThenCompletes() async throws {
        let recorder = EventExecutionRecorder()
        let runtime = AgentRuntime(
            planner: ConfirmationEventPlanner(),
            tools: ToolRuntime(
                registry: ToolRegistry(tools: [EventConfirmedTool(recorder: recorder)])
            )
        )

        let startStream = await runtime.streamStart(goal: "Try the confirmed read tool")
        var waiting: AgentRun?
        for try await event in startStream {
            if case .runUpdated(let run) = event, run.state == .waitingForConfirmation {
                waiting = run
            }
        }

        guard let waiting, let pending = waiting.pendingCall else {
            return XCTFail("Expected pending call.")
        }

        let resumeStream = await runtime.streamResume(
            runID: waiting.id,
            confirmation: ToolConfirmation(callID: pending.id, approved: false)
        )
        var events: [AgentEvent] = []
        for try await event in resumeStream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .toolFinished(_, let result) = event {
                return result.callID == pending.id && result.status == .denied
            }
            return false
        })
        let executionCount = await recorder.count()
        XCTAssertEqual(executionCount, 0)

        guard case .terminal(let finalRun)? = events.last else {
            return XCTFail("Expected terminal run after planner observes rejection.")
        }
        XCTAssertEqual(finalRun.state, .completed)
        XCTAssertEqual(finalRun.steps.last?.result.status, .denied)
    }
}

private struct EventEchoTool: LumiTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "event.echo",
            description: "Return one test value.",
            inputSchema: [
                ToolFieldSchema(
                    name: "value",
                    type: .string,
                    description: "Value to echo.",
                    required: true
                )
            ],
            outputDescription: "Echoed value.",
            access: .readOnly,
            risk: .low
        )
    }

    func execute(arguments: [String: ToolValue]) async throws -> ToolValue {
        arguments["value"] ?? .null
    }
}

private actor EventSequencePlanner: AgentPlanning {
    func decide(_ context: AgentPlanningContext) async throws -> AgentDecision {
        if context.run.steps.isEmpty {
            return .tool(
                name: "event.echo",
                arguments: ["value": .string("hello")],
                note: "Read a deterministic test value."
            )
        }
        return .finish(answer: "Observed the tool result.")
    }
}

private actor EventExecutionRecorder {
    private var executions = 0

    func record() {
        executions += 1
    }

    func count() -> Int {
        executions
    }
}

private struct EventConfirmedTool: LumiTool {
    let recorder: EventExecutionRecorder

    var definition: ToolDefinition {
        ToolDefinition(
            name: "event.confirmed",
            description: "Read-only test tool requiring confirmation.",
            outputDescription: "Confirmed result.",
            access: .readOnly,
            risk: .medium,
            requiresConfirmation: true
        )
    }

    func execute(arguments: [String: ToolValue]) async throws -> ToolValue {
        await recorder.record()
        return .string("approved")
    }
}

private actor ConfirmationEventPlanner: AgentPlanning {
    func decide(_ context: AgentPlanningContext) async throws -> AgentDecision {
        if context.run.steps.isEmpty {
            return .tool(
                name: "event.confirmed",
                arguments: [:],
                note: "Request a confirmed read."
            )
        }

        if context.run.steps.last?.result.status == .denied {
            return .finish(answer: "The user rejected the action; no tool execution occurred.")
        }
        return .finish(answer: "Confirmed observation complete.")
    }
}
