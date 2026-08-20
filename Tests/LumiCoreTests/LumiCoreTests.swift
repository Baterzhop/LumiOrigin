import XCTest
@testable import LumiCore

final class LumiCoreTests: XCTestCase {
    func testIntentRouterDetectsCoding() {
        let router = IntentRouter()
        XCTAssertEqual(router.detect("Please refactor this Swift code"), .coding)
        XCTAssertEqual(router.detect("знайди документ про Ducati"), .knowledge)
    }

    func testKnowledgeSearchRanksRelevantDocumentFirst() async {
        let index = KnowledgeIndex(documents: [
            KnowledgeDocument(id: "finance", title: "Income statement", text: "Revenue and expenses are reported on the income statement."),
            KnowledgeDocument(id: "ai", title: "Neural networks", text: "Neural networks are used in machine learning.")
        ])

        let hits = await index.search("revenue expenses", limit: 2)
        XCTAssertEqual(hits.first?.document.id, "finance")
        XCTAssertGreaterThan(hits.first?.score ?? 0, 0)
    }

    func testPromptRegistryFallsBackToChat() {
        let registry = PromptRegistry()
        XCTAssertEqual(registry.profile(named: "missing").name, "chat")
        XCTAssertTrue(registry.names.contains("coding"))
    }

    func testEnginePersistsConversationAndReflection() async {
        let engine = LumiEngine(llm: LocalFallbackClient())
        let reply = await engine.respond(to: "hello", profile: "chat")
        XCTAssertEqual(reply.intent, .chat)
        XCTAssertEqual(reply.runtime.provider, .localFallback)
        XCTAssertTrue(reply.runtime.fallbackUsed)

        let messages = await engine.messages()
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertEqual(messages.last?.role, .assistant)

        let reflections = await engine.recentReflections()
        XCTAssertEqual(reflections.count, 1)
    }

    func testEngineUsesIntentProfileWhenNoOverrideIsProvided() async {
        let engine = LumiEngine(llm: LocalFallbackClient())
        let reply = await engine.respond(to: "Please refactor this Swift code")

        XCTAssertEqual(reply.intent, .coding)
        XCTAssertEqual(reply.profile, "coding")
    }

    func testLumiRequestCarriesOptionalProfileOverride() {
        let request = LumiRequest(input: "hello", profileOverride: nil)
        XCTAssertEqual(request.input, "hello")
        XCTAssertNil(request.profileOverride)
    }
}
