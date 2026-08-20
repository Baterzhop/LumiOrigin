import XCTest
@testable import LumiCore

final class CitationTests: XCTestCase {
    func testCitationAssemblerAcceptsOnlyMarkersBackedByEvidence() {
        let evidence = [
            KnowledgeHit(
                document: KnowledgeDocument(
                    id: "chunk-1",
                    title: "Ducati Workshop Manual",
                    text: "The engine oil drain plug tightening torque is 20 Nm.",
                    tags: ["ducati"],
                    sourceID: "manual",
                    chunkID: "chunk-1",
                    sourceURI: "file:///manual.pdf",
                    section: "Lubrication system",
                    page: 312
                ),
                score: 1
            ),
            KnowledgeHit(
                document: KnowledgeDocument(
                    id: "chunk-2",
                    title: "Other Section",
                    text: "Suspension setup information.",
                    sourceID: "manual",
                    chunkID: "chunk-2",
                    page: 420
                ),
                score: 0.5
            )
        ]

        let report = CitationAssembler().assemble(
            response: "Tighten it to 20 Nm [S1]. Do not trust invented evidence [S99]. Repeated citation [S1].",
            evidence: evidence
        )

        XCTAssertEqual(report.citations.count, 1)
        XCTAssertEqual(report.citations.first?.marker, "S1")
        XCTAssertEqual(report.citations.first?.sourceID, "manual")
        XCTAssertEqual(report.citations.first?.chunkID, "chunk-1")
        XCTAssertEqual(report.citations.first?.page, 312)
        XCTAssertEqual(report.citations.first?.section, "Lubrication system")
        XCTAssertEqual(report.invalidMarkers, ["S99"])
        XCTAssertEqual(report.availableEvidenceCount, 2)
        XCTAssertEqual(report.uncitedEvidenceCount, 1)
    }

    func testCitationAssemblerRejectsMarkersWhenNoEvidenceExists() {
        let report = CitationAssembler().assemble(
            response: "Unsupported claim [S1] and another [S2].",
            evidence: []
        )

        XCTAssertTrue(report.citations.isEmpty)
        XCTAssertEqual(report.invalidMarkers, ["S1", "S2"])
        XCTAssertEqual(report.availableEvidenceCount, 0)
    }

    func testContextPackerRendersSourceMarkersAndProvenance() {
        let manager = ContextBudgetManager(
            policy: ContextBudgetPolicy(
                contextWindow: 4_096,
                safetyMarginTokens: 128,
                knowledgeFraction: 0.5
            )
        )
        let profile = PromptProfile(
            name: "knowledge",
            system: "Answer from evidence.",
            temperature: 0,
            maxTokens: 256
        )
        let evidence = KnowledgeHit(
            document: KnowledgeDocument(
                id: "manual:312",
                title: "Workshop Manual",
                text: "Drain plug torque: 20 Nm.",
                sourceID: "manual",
                chunkID: "manual:312",
                sourceURI: "file:///manual.pdf",
                section: "Engine oil",
                page: 312
            ),
            score: 1
        )

        let pack = manager.pack(
            profile: profile,
            history: [ChatMessage(role: .user, content: "What is the torque?")],
            knowledge: [evidence]
        )

        XCTAssertTrue(pack.systemPrompt.contains("[S1] Workshop Manual"))
        XCTAssertTrue(pack.systemPrompt.contains("source_id=manual"))
        XCTAssertTrue(pack.systemPrompt.contains("chunk_id=manual:312"))
        XCTAssertTrue(pack.systemPrompt.contains("section=Engine oil"))
        XCTAssertTrue(pack.systemPrompt.contains("page=312"))
        XCTAssertTrue(pack.systemPrompt.contains("untrusted data"))
        XCTAssertTrue(pack.systemPrompt.contains("Never invent a source marker"))
    }

    func testEngineReturnsValidatedCitationReport() async {
        let hit = KnowledgeHit(
            document: KnowledgeDocument(
                id: "torque-chunk",
                title: "Workshop Manual",
                text: "The drain plug tightening torque is 20 Nm.",
                sourceID: "manual",
                chunkID: "torque-chunk",
                sourceURI: "file:///manual.pdf",
                section: "Oil service",
                page: 312
            ),
            score: 1
        )
        let engine = LumiEngine(
            llm: CitationTestClient(),
            knowledge: FixedKnowledgeRetriever(hits: [hit])
        )

        let reply = await engine.respond(
            to: "Find the drain plug torque in the document",
            profile: "knowledge"
        )

        XCTAssertEqual(reply.citationReport.citations.count, 1)
        XCTAssertEqual(reply.citationReport.citations.first?.chunkID, "torque-chunk")
        XCTAssertEqual(reply.citationReport.citations.first?.page, 312)
        XCTAssertTrue(reply.citationReport.invalidMarkers.isEmpty)
    }
}

private struct FixedKnowledgeRetriever: KnowledgeRetrieving {
    let hits: [KnowledgeHit]

    func search(_ query: String, limit: Int) async -> [KnowledgeHit] {
        Array(hits.prefix(max(0, limit)))
    }
}

private struct CitationTestClient: LLMClient {
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        ModelResponse(
            content: "The specified tightening torque is 20 Nm [S1].",
            runtime: RuntimeMetadata(
                provider: .ollama,
                model: "citation-test",
                finishReason: .stop
            )
        )
    }
}
