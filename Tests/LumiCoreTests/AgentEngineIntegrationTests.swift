import XCTest
@testable import LumiCore

final class AgentEngineIntegrationTests: XCTestCase {
    func testEngineStartAgentUsesClassifierAndExplicitAgentRuntime() async throws {
        let planner = EngineScriptedPlanner(decisions: [
            .tool(name: "engine.read", arguments: [:], note: "Read"),
            .finish(answer: "Agent completed explicitly.")
        ])
        let toolRuntime = ToolRuntime(
            registry: ToolRegistry(tools: [EngineReadTool(recorder: nil)])
        )
        let agentRuntime = AgentRuntime(planner: planner, tools: toolRuntime)
        let engine = LumiEngine(
            llm: EngineFixedLLM(),
            toolRuntime: toolRuntime,
            agentRuntime: agentRuntime
        )

        let run = try await engine.startAgent(goal: "Run the script with a tool and report the result.")

        XCTAssertEqual(run.state, .completed)
        XCTAssertEqual(run.finalAnswer, "Agent completed explicitly.")
        XCTAssertEqual(run.classification?.mode, .agent)
        XCTAssertTrue(run.classification?.capabilities.contains(.tools) == true)
        XCTAssertEqual(run.steps.count, 1)
        XCTAssertEqual(run.steps.first?.result.status, .success)
    }

    func testNormalRespondDoesNotAutoStartAgentOrExecuteTool() async {
        let execution = EngineToolRecorder()
        let toolRuntime = ToolRuntime(
            registry: ToolRegistry(tools: [EngineReadTool(recorder: execution)])
        )
        let agentRuntime = AgentRuntime(
            planner: EngineScriptedPlanner(decisions: [
                .tool(name: "engine.read", arguments: [:], note: nil),
                .finish(answer: "unused")
            ]),
            tools: toolRuntime
        )
        let engine = LumiEngine(
            llm: EngineFixedLLM(),
            toolRuntime: toolRuntime,
            agentRuntime: agentRuntime
        )

        let reply = await engine.respond(to: "Run the script with a tool.")
        let executed = await execution.wasExecuted()

        XCTAssertEqual(reply.classification.mode, .agent)
        XCTAssertFalse(executed)
        XCTAssertTrue(reply.message.content.contains("No external action was executed"))
    }

    func testEngineRejectsAgentStartWhenRuntimeIsNotConfigured() async {
        let engine = LumiEngine(llm: EngineFixedLLM())

        do {
            _ = try await engine.startAgent(goal: "Run a tool")
            XCTFail("Expected missing AgentRuntime to be rejected.")
        } catch let error as AgentRuntimeError {
            guard case .invalidState(let detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("not configured"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testEngineAgentResumeUsesPersistedPendingCall() async throws {
        let tools = ToolRuntime(registry: ToolRegistry(tools: [EngineConfirmedReadTool()]))
        let planner = EngineConfirmationPlanner()
        let agentRuntime = AgentRuntime(planner: planner, tools: tools)
        let engine = LumiEngine(
            llm: EngineFixedLLM(),
            toolRuntime: tools,
            agentRuntime: agentRuntime
        )

        let waiting = try await engine.startAgent(goal: "Run command to read protected metadata")
        XCTAssertEqual(waiting.state, .waitingForConfirmation)
        guard let pending = waiting.pendingCall else {
            return XCTFail("Expected pending confirmation.")
        }

        let completed = try await engine.resumeAgent(
            runID: waiting.id,
            confirmation: ToolConfirmation(callID: pending.id, approved: true)
        )
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.steps.first?.call.id, pending.id)
        XCTAssertEqual(completed.finalAnswer, "Confirmed read completed.")
    }
}

private actor EngineScriptedPlanner: AgentPlanning {
    private var decisions: [AgentDecision]

    init(decisions: [AgentDecision]) {
        self.decisions = decisions
    }

    func decide(_ context: AgentPlanningContext) throws -> AgentDecision {
        guard !decisions.isEmpty else {
            throw AgentRuntimeError.plannerFailed("No scripted decision remaining.")
        }
        return decisions.removeFirst()
    }
}

private struct EngineConfirmationPlanner: AgentPlanning {
    func decide(_ context: AgentPlanningContext) async throws -> AgentDecision {
        if context.run.steps.isEmpty {
            return .tool(name: "engine.confirmed_read", arguments: [:], note: "Read protected metadata")
        }
        if context.run.steps.last?.result.status == .success {
            return .finish(answer: "Confirmed read completed.")
        }
        return .finish(answer: "Confirmed read did not complete.")
    }
}

private actor EngineToolRecorder {
    private var executed = false

    func markExecuted() {
        executed = true
    }

    func wasExecuted() -> Bool {
        executed
    }
}

private struct EngineReadTool: LumiTool {
    let recorder: EngineToolRecorder?

    var definition: ToolDefinition {
        ToolDefinition(
            name: "engine.read",
            description: "Read engine test data.",
            outputDescription: "Engine test data.",
            access: .readOnly,
            risk: .low
        )
    }

    func execute(arguments: [String: ToolValue]) async throws -> ToolValue {
        if let recorder {
            await recorder.markExecuted()
        }
        return .string("engine-value")
    }
}

private struct EngineConfirmedReadTool: LumiTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "engine.confirmed_read",
            description: "Read protected engine test data.",
            outputDescription: "Protected engine test data.",
            access: .readOnly,
            risk: .medium,
            requiresConfirmation: true
        )
    }

    func execute(arguments: [String: ToolValue]) async throws -> ToolValue {
        .string("confirmed-engine-value")
    }
}

private struct EngineFixedLLM: LLMClient {
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        ModelResponse(
            content: "No external action was executed; use explicit AgentRuntime for actions.",
            runtime: RuntimeMetadata(
                provider: .localFallback,
                model: "engine-agent-test",
                fallbackUsed: true,
                finishReason: .stop
            )
        )
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(
                ModelResponse(
                    content: "No external action was executed; use explicit AgentRuntime for actions.",
                    runtime: RuntimeMetadata(
                        provider: .localFallback,
                        model: "engine-agent-test",
                        fallbackUsed: true,
                        finishReason: .stop
                    )
                )
            ))
            continuation.finish()
        }
    }
}
