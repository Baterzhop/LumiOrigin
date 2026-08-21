import XCTest
@testable import LumiCore

final class AgentPlannerModelRoleTests: XCTestCase {
    func testPlannerSendsExplicitAgentPlannerRole() async throws {
        let recorder = PlannerRoleRecorder()
        let planner = LLMAgentPlanner(llm: PlannerRoleClient(recorder: recorder))
        let run = AgentRun(goal: "Answer without tools")

        let decision = try await planner.decide(
            AgentPlanningContext(run: run, availableTools: [])
        )

        XCTAssertEqual(decision, .finish(answer: "Done"))
        let role = await recorder.role()
        XCTAssertEqual(role, .agentPlanner)
    }
}

private actor PlannerRoleRecorder {
    private var capturedRole: ModelRole?

    func record(_ request: ModelRequest) {
        capturedRole = request.role
    }

    func role() -> ModelRole? {
        capturedRole
    }
}

private struct PlannerRoleClient: LLMClient {
    let recorder: PlannerRoleRecorder

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        await recorder.record(request)
        return ModelResponse(
            content: "{\"action\":\"finish\",\"answer\":\"Done\"}",
            runtime: RuntimeMetadata(
                provider: .unknown,
                model: "planner-role-test",
                finishReason: .stop
            )
        )
    }
}
