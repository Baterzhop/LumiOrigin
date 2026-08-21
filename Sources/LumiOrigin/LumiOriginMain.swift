import Foundation
import LumiCore

#if canImport(SwiftUI)
import SwiftUI

@main
struct LumiOriginApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
    }
}
#else
#if os(Linux)
import Glibc
#endif

@main
struct LumiOriginCLI {
    static func main() async {
        let arguments = Set(CommandLine.arguments.dropFirst())
        if arguments.contains("--eval") {
            await runEvaluations()
            return
        }

        let engine = LumiEngine(llm: LocalFallbackClient())
        let reply = await engine.respond(to: "Hello from Lumi")
        print(reply.message.content)
    }

    private static func runEvaluations() async {
        let harness = EvaluationHarness()
        let routing = harness.evaluateRouting(
            classifier: HeuristicRequestClassifier(),
            cases: LumiBaselineEvaluations.routing
        )
        let retrieval = await harness.evaluateRetrieval(
            retriever: KnowledgeIndex(documents: LumiEngine.bootstrapKnowledge),
            cases: LumiBaselineEvaluations.bootstrapRetrieval
        )

        print("Lumi offline evaluation")
        print("Routing: \(routing.summary.passed)/\(routing.summary.total) (\(percent(routing.summary.passRate)))")
        print("Retrieval: \(retrieval.summary.passed)/\(retrieval.summary.total) (\(percent(retrieval.summary.passRate)))")
        print("Recall@K: \(formatted(retrieval.summary.meanRecallAtK))")
        print("MRR: \(formatted(retrieval.summary.meanReciprocalRank))")

        let failedRouting = routing.results.filter { !$0.passed }
        for result in failedRouting {
            print("FAIL routing \(result.id): expected=\(result.expectedMode.rawValue) actual=\(result.actualMode.rawValue) missing=\(result.missingCapabilities.map(\.rawValue).sorted())")
        }

        let failedRetrieval = retrieval.results.filter { !$0.passed }
        for result in failedRetrieval {
            print("FAIL retrieval \(result.id): retrieved=\(result.retrievedDocumentIDs) relevant=\(result.relevantDocumentIDs.sorted())")
        }

        if !failedRouting.isEmpty || !failedRetrieval.isEmpty {
            exit(2)
        }
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func formatted(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.3f", value)
    }
}
#endif
