import XCTest
@testable import LumiCore

final class ModelRouterTests: XCTestCase {
    func testExplicitRoleOverridesProfileFallback() {
        let request = makeRequest(profile: "coding", role: .knowledge)
        let policy = ModelRoutingPolicy()

        XCTAssertEqual(policy.role(for: request), .knowledge)
    }

    func testProfileFallbackMapsKnownGenerationRoles() {
        let policy = ModelRoutingPolicy()

        XCTAssertEqual(policy.role(for: makeRequest(profile: "chat")), .chat)
        XCTAssertEqual(policy.role(for: makeRequest(profile: "knowledge")), .knowledge)
        XCTAssertEqual(policy.role(for: makeRequest(profile: "coding")), .coding)
        XCTAssertEqual(policy.role(for: makeRequest(profile: "reflection")), .reflection)
        XCTAssertEqual(policy.role(for: makeRequest(profile: "agent-planner")), .agentPlanner)
        XCTAssertEqual(policy.role(for: makeRequest(profile: "custom-profile")), .chat)
    }

    func testCompleteRoutesToRoleSpecificClientAndAnnotatesMetadata() async throws {
        let recorder = ModelRouteRecorder()
        let router = ModelRouter(
            defaultClient: RoutedTestClient(id: "chat-model", recorder: recorder),
            routes: [
                .coding: RoutedTestClient(id: "coding-model", recorder: recorder),
                .knowledge: RoutedTestClient(id: "knowledge-model", recorder: recorder)
            ]
        )

        let coding = try await router.complete(makeRequest(profile: "coding"))
        let knowledge = try await router.complete(makeRequest(profile: "knowledge"))
        let chat = try await router.complete(makeRequest(profile: "unknown"))

        XCTAssertEqual(coding.runtime.model, "coding-model")
        XCTAssertEqual(coding.runtime.modelRole, .coding)
        XCTAssertEqual(knowledge.runtime.model, "knowledge-model")
        XCTAssertEqual(knowledge.runtime.modelRole, .knowledge)
        XCTAssertEqual(chat.runtime.model, "chat-model")
        XCTAssertEqual(chat.runtime.modelRole, .chat)

        let ids = await recorder.ids()
        XCTAssertEqual(ids, ["coding-model", "knowledge-model", "chat-model"])
    }

    func testAgentPlannerProfileRoutesToAgentModel() async throws {
        let recorder = ModelRouteRecorder()
        let router = ModelRouter(
            defaultClient: RoutedTestClient(id: "chat-model", recorder: recorder),
            routes: [
                .agentPlanner: RoutedTestClient(id: "agent-model", recorder: recorder)
            ]
        )

        let response = try await router.complete(makeRequest(profile: "agent-planner"))

        XCTAssertEqual(response.runtime.model, "agent-model")
        XCTAssertEqual(response.runtime.modelRole, .agentPlanner)
        let ids = await recorder.ids()
        XCTAssertEqual(ids, ["agent-model"])
    }

    func testStreamingPreservesTokensAndAnnotatesCompletedRole() async throws {
        let recorder = ModelRouteRecorder()
        let router = ModelRouter(
            defaultClient: RoutedTestClient(id: "chat-model", recorder: recorder),
            routes: [
                .coding: RoutedTestClient(id: "coding-model", recorder: recorder)
            ]
        )

        let stream = router.stream(makeRequest(profile: "coding"))
        var tokens = ""
        var completed: ModelResponse?

        for try await event in stream {
            switch event {
            case .token(let token): tokens += token
            case .completed(let response): completed = response
            }
        }

        XCTAssertEqual(tokens, "coding-model")
        XCTAssertEqual(completed?.content, "coding-model")
        XCTAssertEqual(completed?.runtime.model, "coding-model")
        XCTAssertEqual(completed?.runtime.modelRole, .coding)
    }

    private func makeRequest(
        profile name: String,
        role: ModelRole? = nil
    ) -> ModelRequest {
        let profile = PromptProfile(
            name: name,
            system: "test",
            temperature: 0,
            topP: 1,
            maxTokens: 32
        )
        return ModelRequest(
            messages: [ChatMessage(role: .user, content: "test")],
            systemPrompt: "test",
            profile: profile,
            role: role
        )
    }
}

private actor ModelRouteRecorder {
    private var selectedIDs: [String] = []

    func record(_ id: String) {
        selectedIDs.append(id)
    }

    func ids() -> [String] {
        selectedIDs
    }
}

private struct RoutedTestClient: LLMClient {
    let id: String
    let recorder: ModelRouteRecorder

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        await recorder.record(id)
        return ModelResponse(
            content: id,
            runtime: RuntimeMetadata(
                provider: .unknown,
                model: id,
                fallbackUsed: false,
                latencyMs: 1,
                finishReason: .stop,
                usage: ModelUsage(inputTokens: 3, outputTokens: 1)
            )
        )
    }
}
