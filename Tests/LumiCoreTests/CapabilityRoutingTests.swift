import XCTest
@testable import LumiCore

final class CapabilityRoutingTests: XCTestCase {
    func testDirectRequestUsesReasoningOnly() {
        let classifier = HeuristicRequestClassifier()
        let result = classifier.classify(LumiRequest(input: "Explain why the sky appears blue."))

        XCTAssertEqual(result.mode, .direct)
        XCTAssertEqual(result.risk, .low)
        XCTAssertEqual(result.capabilities, [.reasoning])
        XCTAssertFalse(result.reasons.isEmpty)
    }

    func testClassifierSupportsCodingRetrievalAndFilesTogether() {
        let classifier = HeuristicRequestClassifier()
        let result = classifier.classify(
            LumiRequest(input: "Find the uploaded Swift file and refactor the code in it.")
        )

        XCTAssertEqual(result.mode, .knowledge)
        XCTAssertTrue(result.capabilities.contains(.reasoning))
        XCTAssertTrue(result.capabilities.contains(.coding))
        XCTAssertTrue(result.capabilities.contains(.retrieval))
        XCTAssertTrue(result.capabilities.contains(.files))
        XCTAssertGreaterThanOrEqual(result.confidence, 0.9)
    }

    func testDestructiveToolRequestIsAgentModeAndHighRisk() {
        let result = HeuristicRequestClassifier().classify(
            LumiRequest(input: "Delete the file and push commit to the repository.")
        )

        XCTAssertEqual(result.mode, .agent)
        XCTAssertEqual(result.risk, .high)
        XCTAssertTrue(result.capabilities.contains(.tools))
        XCTAssertTrue(result.capabilities.contains(.files))
        XCTAssertTrue(result.capabilities.contains(.coding))
    }

    func testLiveWebRequestRequiresAgentCapability() {
        let result = HeuristicRequestClassifier().classify(
            LumiRequest(input: "Search the web for the latest release and current price.")
        )

        XCTAssertEqual(result.mode, .agent)
        XCTAssertTrue(result.capabilities.contains(.web))
        XCTAssertTrue(result.capabilities.contains(.retrieval))
        XCTAssertEqual(result.risk, .low)
    }

    func testProfileOverrideParticipatesInClassification() {
        let result = HeuristicRequestClassifier().classify(
            LumiRequest(input: "Explain the relevant material.", profileOverride: "knowledge")
        )

        XCTAssertEqual(result.mode, .knowledge)
        XCTAssertTrue(result.capabilities.contains(.retrieval))
        XCTAssertTrue(result.reasons.contains("knowledge profile override"))
    }

    func testEngineRunsRetrievalFromCapabilityEvenWithChatProfile() async {
        let knowledge = RoutingKnowledgeRecorder()
        let engine = LumiEngine(
            llm: RoutingRecordingClient(recorder: RoutingRequestRecorder()),
            knowledge: knowledge
        )

        let reply = await engine.respond(to: "Find the document about torque settings", profile: "chat")
        let calls = await knowledge.callCount()

        XCTAssertEqual(reply.classification.mode, .knowledge)
        XCTAssertTrue(reply.classification.capabilities.contains(.retrieval))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(reply.context.first?.document.id, "routing-hit")
    }

    func testDirectRequestDoesNotPayRetrievalCost() async {
        let knowledge = RoutingKnowledgeRecorder()
        let engine = LumiEngine(
            llm: RoutingRecordingClient(recorder: RoutingRequestRecorder()),
            knowledge: knowledge
        )

        let reply = await engine.respond(to: "Explain binary search simply", profile: "chat")
        let calls = await knowledge.callCount()

        XCTAssertEqual(reply.classification.mode, .direct)
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(reply.context.isEmpty)
    }

    func testUnconfiguredToolCapabilityAddsTruthfulRuntimeBoundary() async {
        let recorder = RoutingRequestRecorder()
        let engine = LumiEngine(llm: RoutingRecordingClient(recorder: recorder))

        let reply = await engine.respond(to: "Delete the file and push commit to the repository.")
        let prompt = await recorder.lastSystemPrompt()

        XCTAssertEqual(reply.classification.mode, .agent)
        XCTAssertEqual(reply.classification.risk, .high)
        XCTAssertTrue(prompt?.contains("not configured in this runtime") == true)
        XCTAssertTrue(prompt?.contains("Clearly distinguish") == true)
        XCTAssertTrue(prompt?.contains("External tools/actions") == true)
    }
}

private actor RoutingKnowledgeRecorder: KnowledgeRetrieving {
    private var calls = 0

    func search(_ query: String, limit: Int) -> [KnowledgeHit] {
        calls += 1
        return [
            KnowledgeHit(
                document: KnowledgeDocument(
                    id: "routing-hit",
                    title: "Routing Test",
                    text: "Torque setting evidence."
                ),
                score: 1
            )
        ]
    }

    func callCount() -> Int {
        calls
    }
}

private actor RoutingRequestRecorder {
    private var systemPrompt: String?

    func record(_ request: ModelRequest) {
        systemPrompt = request.systemPrompt
    }

    func lastSystemPrompt() -> String? {
        systemPrompt
    }
}

private struct RoutingRecordingClient: LLMClient {
    let recorder: RoutingRequestRecorder

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        await recorder.record(request)
        return response
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await recorder.record(request)
                continuation.yield(.token("OK"))
                continuation.yield(.completed(response))
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private var response: ModelResponse {
        ModelResponse(
            content: "OK",
            runtime: RuntimeMetadata(
                provider: .localFallback,
                model: "routing-test",
                fallbackUsed: true,
                finishReason: .stop
            )
        )
    }
}
