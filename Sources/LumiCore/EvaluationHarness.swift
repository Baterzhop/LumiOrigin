import Foundation

public struct RoutingEvalCase: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let input: String
    public let profileOverride: String?
    public let expectedMode: ExecutionMode
    public let requiredCapabilities: Set<LumiCapability>
    public let expectedRisk: RiskLevel?

    public init(
        id: String,
        input: String,
        profileOverride: String? = nil,
        expectedMode: ExecutionMode,
        requiredCapabilities: Set<LumiCapability> = [],
        expectedRisk: RiskLevel? = nil
    ) {
        self.id = id
        self.input = input
        self.profileOverride = profileOverride
        self.expectedMode = expectedMode
        self.requiredCapabilities = requiredCapabilities
        self.expectedRisk = expectedRisk
    }
}

public struct RoutingEvalResult: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let passed: Bool
    public let expectedMode: ExecutionMode
    public let actualMode: ExecutionMode
    public let missingCapabilities: Set<LumiCapability>
    public let expectedRisk: RiskLevel?
    public let actualRisk: RiskLevel
    public let confidence: Double

    public init(testCase: RoutingEvalCase, actual: RequestClassification) {
        let missing = testCase.requiredCapabilities.subtracting(actual.capabilities)
        let riskMatches = testCase.expectedRisk.map { $0 == actual.risk } ?? true
        self.id = testCase.id
        self.passed = actual.mode == testCase.expectedMode && missing.isEmpty && riskMatches
        self.expectedMode = testCase.expectedMode
        self.actualMode = actual.mode
        self.missingCapabilities = missing
        self.expectedRisk = testCase.expectedRisk
        self.actualRisk = actual.risk
        self.confidence = actual.confidence
    }
}

public struct RetrievalEvalCase: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let query: String
    public let relevantDocumentIDs: Set<String>
    public let topK: Int

    public init(
        id: String,
        query: String,
        relevantDocumentIDs: Set<String>,
        topK: Int = 5
    ) {
        self.id = id
        self.query = query
        self.relevantDocumentIDs = relevantDocumentIDs
        self.topK = max(1, min(topK, 100))
    }
}

public struct RetrievalEvalResult: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let retrievedDocumentIDs: [String]
    public let relevantDocumentIDs: Set<String>
    public let recallAtK: Double
    public let reciprocalRank: Double
    public let passed: Bool

    public init(testCase: RetrievalEvalCase, hits: [KnowledgeHit]) {
        let ids = hits.prefix(testCase.topK).map { $0.document.id }
        let retrievedRelevant = Set(ids).intersection(testCase.relevantDocumentIDs)
        let denominator = max(1, testCase.relevantDocumentIDs.count)
        let recall = Double(retrievedRelevant.count) / Double(denominator)

        let firstRelevantRank = ids.firstIndex { testCase.relevantDocumentIDs.contains($0) }
            .map { $0 + 1 }
        let reciprocal = firstRelevantRank.map { 1.0 / Double($0) } ?? 0

        self.id = testCase.id
        self.retrievedDocumentIDs = ids
        self.relevantDocumentIDs = testCase.relevantDocumentIDs
        self.recallAtK = recall
        self.reciprocalRank = reciprocal
        self.passed = recall >= 1.0
    }
}

public struct EvaluationSummary: Codable, Hashable, Sendable {
    public let total: Int
    public let passed: Int
    public let passRate: Double
    public let meanRecallAtK: Double?
    public let meanReciprocalRank: Double?

    public init(
        total: Int,
        passed: Int,
        meanRecallAtK: Double? = nil,
        meanReciprocalRank: Double? = nil
    ) {
        self.total = max(0, total)
        self.passed = max(0, min(passed, total))
        self.passRate = total > 0 ? Double(self.passed) / Double(total) : 1
        self.meanRecallAtK = meanRecallAtK
        self.meanReciprocalRank = meanReciprocalRank
    }
}

public struct RoutingEvaluationReport: Codable, Hashable, Sendable {
    public let results: [RoutingEvalResult]
    public let summary: EvaluationSummary
}

public struct RetrievalEvaluationReport: Codable, Hashable, Sendable {
    public let results: [RetrievalEvalResult]
    public let summary: EvaluationSummary
}

public struct EvaluationHarness: Sendable {
    public init() {}

    public func evaluateRouting(
        classifier: any RequestClassifying,
        cases: [RoutingEvalCase]
    ) -> RoutingEvaluationReport {
        let results = cases.map { testCase in
            let actual = classifier.classify(
                LumiRequest(
                    input: testCase.input,
                    profileOverride: testCase.profileOverride
                )
            )
            return RoutingEvalResult(testCase: testCase, actual: actual)
        }

        return RoutingEvaluationReport(
            results: results,
            summary: EvaluationSummary(
                total: results.count,
                passed: results.filter(\.passed).count
            )
        )
    }

    public func evaluateRetrieval(
        retriever: any KnowledgeRetrieving,
        cases: [RetrievalEvalCase]
    ) async -> RetrievalEvaluationReport {
        var results: [RetrievalEvalResult] = []
        results.reserveCapacity(cases.count)

        for testCase in cases {
            let hits = await retriever.search(testCase.query, limit: testCase.topK)
            results.append(RetrievalEvalResult(testCase: testCase, hits: hits))
        }

        let recall = mean(results.map(\.recallAtK))
        let mrr = mean(results.map(\.reciprocalRank))
        return RetrievalEvaluationReport(
            results: results,
            summary: EvaluationSummary(
                total: results.count,
                passed: results.filter(\.passed).count,
                meanRecallAtK: recall,
                meanReciprocalRank: mrr
            )
        )
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

public enum LumiBaselineEvaluations {
    public static let routing: [RoutingEvalCase] = [
        RoutingEvalCase(
            id: "direct-explanation",
            input: "Explain binary search simply.",
            expectedMode: .direct,
            requiredCapabilities: [.reasoning],
            expectedRisk: .low
        ),
        RoutingEvalCase(
            id: "knowledge-document",
            input: "Find the document about torque settings.",
            expectedMode: .knowledge,
            requiredCapabilities: [.retrieval]
        ),
        RoutingEvalCase(
            id: "coding-file",
            input: "Find the uploaded Swift file and refactor the code in it.",
            expectedMode: .knowledge,
            requiredCapabilities: [.coding, .files, .retrieval]
        ),
        RoutingEvalCase(
            id: "agent-destructive",
            input: "Delete the file and push the commit.",
            expectedMode: .agent,
            requiredCapabilities: [.tools, .files, .coding],
            expectedRisk: .high
        ),
        RoutingEvalCase(
            id: "live-web",
            input: "Search the web for the latest release and current price.",
            expectedMode: .agent,
            requiredCapabilities: [.web, .retrieval]
        )
    ]
}
