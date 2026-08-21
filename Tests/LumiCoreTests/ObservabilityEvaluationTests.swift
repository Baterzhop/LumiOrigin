import XCTest
@testable import LumiCore

final class ObservabilityEvaluationTests: XCTestCase {
    func testSQLiteRuntimeTracePersistsAcrossStoreInstances() async throws {
        let databaseURL = temporaryDirectory("runtime-trace")
            .appendingPathComponent("trace.sqlite3")
        let requestID = UUID()
        let conversationID = UUID()
        let trace = makeTrace(requestID: requestID, conversationID: conversationID)

        let first = SQLiteRuntimeTraceStore(databaseURL: databaseURL)
        try await first.append(trace)

        let second = SQLiteRuntimeTraceStore(databaseURL: databaseURL)
        let restored = try await second.recent(limit: 10)

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.requestID, requestID)
        XCTAssertEqual(restored.first?.conversationID, conversationID)
        XCTAssertEqual(restored.first?.modelRole, .knowledge)
        XCTAssertEqual(restored.first?.citationCount, 1)
    }

    func testEngineRecordsMetadataOnlyTraceForCompletedRequest() async {
        let telemetry = RuntimeTelemetry()
        let requestID = UUID()
        let engine = LumiEngine(
            llm: TelemetryTestClient(),
            telemetry: telemetry
        )

        _ = await engine.respond(
            LumiRequest(id: requestID, input: "Explain binary search simply.")
        )

        let traces = await engine.recentRuntimeTraces(limit: 10)
        XCTAssertEqual(traces.count, 1)
        XCTAssertEqual(traces.first?.requestID, requestID)
        XCTAssertEqual(traces.first?.mode, .direct)
        XCTAssertEqual(traces.first?.provider, .unknown)
        XCTAssertEqual(traces.first?.model, "telemetry-test")
        XCTAssertEqual(traces.first?.modelRole, .chat)
        XCTAssertEqual(traces.first?.inputTokens, 12)
        XCTAssertEqual(traces.first?.outputTokens, 4)
        XCTAssertEqual(traces.first?.outcome, .completed)
    }

    func testStreamedRequestRecordsExactlyOneTrace() async throws {
        let telemetry = RuntimeTelemetry()
        let engine = LumiEngine(
            llm: TelemetryTestClient(),
            telemetry: telemetry
        )

        let stream = await engine.streamRespond(to: "Explain a queue.")
        var completedReplies = 0
        for try await event in stream {
            if case .completed = event {
                completedReplies += 1
            }
        }

        let traces = await engine.recentRuntimeTraces(limit: 10)
        XCTAssertEqual(completedReplies, 1)
        XCTAssertEqual(traces.count, 1)
    }

    func testConversationClearDoesNotDeleteTelemetry() async {
        let telemetry = RuntimeTelemetry()
        let engine = LumiEngine(
            llm: TelemetryTestClient(),
            telemetry: telemetry
        )

        _ = await engine.respond(to: "Explain a stack.")
        await engine.clearConversation()

        let traces = await engine.recentRuntimeTraces(limit: 10)
        let messages = await engine.messages()
        XCTAssertEqual(traces.count, 1)
        XCTAssertTrue(messages.isEmpty)
    }

    func testBaselineRoutingEvaluationPasses() {
        let report = EvaluationHarness().evaluateRouting(
            classifier: HeuristicRequestClassifier(),
            cases: LumiBaselineEvaluations.routing
        )

        XCTAssertEqual(report.summary.total, LumiBaselineEvaluations.routing.count)
        XCTAssertEqual(report.summary.passed, report.summary.total)
        XCTAssertEqual(report.summary.passRate, 1, accuracy: 0.0001)
        XCTAssertTrue(report.results.allSatisfy(\.passed))
    }

    func testRetrievalEvaluationComputesRecallAndMRR() async {
        let retriever = KnowledgeIndex(documents: [
            KnowledgeDocument(
                id: "torque",
                title: "Ducati torque settings",
                text: "Rear axle torque chain adjustment workshop specification."
            ),
            KnowledgeDocument(
                id: "weather",
                title: "Weather notes",
                text: "Rain clouds and temperature forecast."
            )
        ])
        let testCase = RetrievalEvalCase(
            id: "ducati-torque",
            query: "Ducati torque chain adjustment",
            relevantDocumentIDs: ["torque"],
            topK: 2
        )

        let report = await EvaluationHarness().evaluateRetrieval(
            retriever: retriever,
            cases: [testCase]
        )

        XCTAssertEqual(report.summary.total, 1)
        XCTAssertEqual(report.summary.passed, 1)
        XCTAssertEqual(report.summary.meanRecallAtK ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(report.summary.meanReciprocalRank ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(report.results.first?.retrievedDocumentIDs.first, "torque")
    }

    private func makeTrace(requestID: UUID, conversationID: UUID) -> RuntimeTrace {
        let classification = RequestClassification(
            mode: .knowledge,
            capabilities: [.reasoning, .retrieval],
            confidence: 0.92,
            risk: .low
        )
        let runtime = RuntimeMetadata(
            provider: .ollama,
            model: "test-model",
            modelRole: .knowledge,
            latencyMs: 25,
            finishReason: .stop,
            usage: ModelUsage(inputTokens: 100, outputTokens: 20)
        )
        let budget = ContextBudgetReport(
            contextWindow: 8_192,
            reservedOutputTokens: 512,
            safetyMarginTokens: 512,
            inputBudgetTokens: 7_168,
            estimatedInputTokens: 500,
            systemTokens: 100,
            historyTokens: 150,
            knowledgeTokens: 250,
            memoryTokens: 0,
            selectedMessageCount: 4,
            droppedMessageCount: 0,
            selectedKnowledgeCount: 2,
            droppedKnowledgeCount: 0,
            selectedMemoryCount: 0,
            droppedMemoryCount: 0,
            fits: true
        )
        let citation = Citation(
            referenceIndex: 1,
            sourceID: "source",
            chunkID: "chunk",
            title: "Source",
            sourceURI: nil,
            section: nil,
            page: nil,
            excerpt: "Evidence"
        )
        let citationReport = CitationReport(
            citations: [citation],
            invalidMarkers: [],
            availableEvidenceCount: 2,
            uncitedEvidenceCount: 1
        )

        return RuntimeTrace(
            requestID: requestID,
            conversationID: conversationID,
            durationMs: 40,
            outcome: .completed,
            classification: classification,
            profile: "knowledge",
            runtime: runtime,
            contextBudget: budget,
            citationReport: citationReport
        )
    }

    private func temporaryDirectory(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}

private struct TelemetryTestClient: LLMClient {
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        ModelResponse(
            content: "Test response.",
            runtime: RuntimeMetadata(
                provider: .unknown,
                model: "telemetry-test",
                modelRole: request.role ?? .chat,
                latencyMs: 3,
                finishReason: .stop,
                usage: ModelUsage(inputTokens: 12, outputTokens: 4)
            )
        )
    }
}
