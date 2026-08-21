import XCTest
@testable import LumiCore

final class ContextToolTests: XCTestCase {
    func testKnowledgeAndMemoryToolsAreLowRiskReadOnlyBoundedAndAudited() async throws {
        let knowledge = KnowledgeIndex(documents: [
            KnowledgeDocument(
                id: "torque-doc",
                title: "Workshop torque table",
                text: String(repeating: "Drain plug torque is 20 Nm. ", count: 20),
                tags: ["motorcycle", "torque"],
                sourceID: "manual",
                chunkID: "manual:torque:1",
                sourceURI: "file:///manual.md",
                section: "Engine",
                page: 42
            )
        ])
        let memory = MemoryRuntime(
            repository: SQLiteMemoryRepository(databaseURL: temporaryDatabase("context-tools-memory"))
        )
        _ = try await memory.remember(
            "User prefers Hungarian for translation output.",
            importance: 0.9,
            isPinned: true,
            tags: ["language", "translation"]
        )

        let audit = InMemoryToolAuditStore()
        let registry = ToolRegistry(tools: [
            KnowledgeSearchTool(knowledge: knowledge, maxResults: 4, maxExcerptCharacters: 120),
            MemorySearchTool(memory: memory, maxResults: 4, maxContentCharacters: 120)
        ])
        let runtime = ToolRuntime(registry: registry, auditStore: audit)

        let definitions = await runtime.availableTools()
        XCTAssertEqual(definitions.map(\.name), ["knowledge.search", "memory.search"])
        XCTAssertTrue(definitions.allSatisfy { $0.access == .readOnly && $0.risk == .low })
        XCTAssertTrue(definitions.allSatisfy { !$0.requiresConfirmation })

        let knowledgeCall = ToolCall(
            toolName: "knowledge.search",
            arguments: [
                "query": .string("drain plug torque"),
                "limit": .integer(1)
            ],
            origin: .agent
        )
        let knowledgeResult = await runtime.execute(knowledgeCall)
        XCTAssertEqual(knowledgeResult.status, .success)
        XCTAssertEqual(knowledgeResult.trust, .untrusted)

        let knowledgeObject = try object(knowledgeResult.output)
        XCTAssertEqual(integer(knowledgeObject["count"]), 1)
        let knowledgeResults = try array(knowledgeObject["results"])
        XCTAssertEqual(knowledgeResults.count, 1)
        let firstKnowledge = try object(knowledgeResults.first)
        XCTAssertEqual(string(firstKnowledge["sourceID"]), "manual")
        XCTAssertEqual(string(firstKnowledge["chunkID"]), "manual:torque:1")
        XCTAssertEqual(integer(firstKnowledge["page"]), 42)
        XCTAssertTrue(string(firstKnowledge["excerpt"])?.hasSuffix("…[truncated]") == true)

        let memoryCall = ToolCall(
            toolName: "memory.search",
            arguments: ["query": .string("Hungarian translation language")],
            origin: .agent
        )
        let memoryResult = await runtime.execute(memoryCall)
        XCTAssertEqual(memoryResult.status, .success)
        XCTAssertEqual(memoryResult.trust, .untrusted)

        let memoryObject = try object(memoryResult.output)
        XCTAssertEqual(integer(memoryObject["count"]), 1)
        let memoryResults = try array(memoryObject["results"])
        let firstMemory = try object(memoryResults.first)
        XCTAssertEqual(string(firstMemory["kind"]), MemoryKind.semantic.rawValue)
        XCTAssertEqual(boolean(firstMemory["pinned"]), true)
        XCTAssertTrue(string(firstMemory["content"])?.contains("Hungarian") == true)

        let auditEvents = await runtime.recentAudit(limit: 10)
        XCTAssertEqual(auditEvents.count, 2)
        XCTAssertEqual(Set(auditEvents.map { $0.call.toolName }), Set(["knowledge.search", "memory.search"]))
        XCTAssertTrue(auditEvents.allSatisfy { $0.permission.status == .allowed })
        XCTAssertTrue(auditEvents.allSatisfy { $0.resultStatus == .success })
    }

    func testContextToolsRejectEmptyQueriesAndOversizedLimitsThroughToolRuntime() async throws {
        let knowledge = KnowledgeIndex(documents: [])
        let runtime = ToolRuntime(
            registry: ToolRegistry(tools: [KnowledgeSearchTool(knowledge: knowledge, maxResults: 3)])
        )

        let emptyQuery = await runtime.execute(
            ToolCall(
                toolName: "knowledge.search",
                arguments: ["query": .string("   ")],
                origin: .agent
            )
        )
        XCTAssertEqual(emptyQuery.status, .failed)
        XCTAssertTrue(emptyQuery.error?.contains("must not be empty") == true)

        let oversizedLimit = await runtime.execute(
            ToolCall(
                toolName: "knowledge.search",
                arguments: [
                    "query": .string("anything"),
                    "limit": .integer(99)
                ],
                origin: .agent
            )
        )
        XCTAssertEqual(oversizedLimit.status, .failed)
        XCTAssertTrue(oversizedLimit.error?.contains("between 1 and 3") == true)

        let wrongType = await runtime.execute(
            ToolCall(
                toolName: "knowledge.search",
                arguments: ["query": .integer(12)],
                origin: .agent
            )
        )
        XCTAssertEqual(wrongType.status, .failed)
        XCTAssertTrue(wrongType.error?.contains("must have type `string`") == true)
    }

    func testAgentRuntimeCanSearchKnowledgeThroughNormalAuditedToolPath() async throws {
        let knowledge = KnowledgeIndex(documents: [
            KnowledgeDocument(
                id: "architecture",
                title: "Lumi architecture",
                text: "AgentRuntime executes typed tools only through ToolRuntime and treats tool output as untrusted data.",
                tags: ["agent", "security"]
            )
        ])
        let audit = InMemoryToolAuditStore()
        let tools = ToolRuntime(
            registry: ToolRegistry(tools: [KnowledgeSearchTool(knowledge: knowledge)]),
            auditStore: audit
        )
        let agent = AgentRuntime(planner: ContextSearchPlanner(), tools: tools)

        let run = try await agent.start(goal: "Find how AgentRuntime executes tools")

        XCTAssertEqual(run.state, .completed)
        XCTAssertEqual(run.steps.count, 1)
        XCTAssertEqual(run.steps.first?.call.toolName, "knowledge.search")
        XCTAssertEqual(run.steps.first?.result.status, .success)
        XCTAssertEqual(run.steps.first?.result.trust, .untrusted)
        XCTAssertEqual(run.finalAnswer, "Knowledge observation received through ToolRuntime.")

        let events = await tools.recentAudit(limit: 10)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.call.origin, .agent)
        XCTAssertEqual(events.first?.call.toolName, "knowledge.search")
        XCTAssertEqual(events.first?.permission.status, .allowed)
    }

    private func temporaryDatabase(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-\(prefix)-\(UUID().uuidString).sqlite3")
    }

    private func object(_ value: ToolValue?) throws -> [String: ToolValue] {
        guard case .object(let object)? = value else {
            throw TestError.unexpectedToolValue
        }
        return object
    }

    private func array(_ value: ToolValue?) throws -> [ToolValue] {
        guard case .array(let array)? = value else {
            throw TestError.unexpectedToolValue
        }
        return array
    }

    private func string(_ value: ToolValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    private func integer(_ value: ToolValue?) -> Int? {
        guard case .integer(let integer)? = value else { return nil }
        return integer
    }

    private func boolean(_ value: ToolValue?) -> Bool? {
        guard case .boolean(let boolean)? = value else { return nil }
        return boolean
    }
}

private enum TestError: Error {
    case unexpectedToolValue
}

private actor ContextSearchPlanner: AgentPlanning {
    func decide(_ context: AgentPlanningContext) async throws -> AgentDecision {
        if context.run.steps.isEmpty {
            guard context.availableTools.contains(where: { $0.name == "knowledge.search" }) else {
                return .finish(answer: "knowledge.search is unavailable.")
            }
            return .tool(
                name: "knowledge.search",
                arguments: [
                    "query": .string("AgentRuntime ToolRuntime untrusted output"),
                    "limit": .integer(2)
                ],
                note: "Search local knowledge."
            )
        }

        guard context.run.steps.last?.result.status == .success else {
            return .finish(answer: "Knowledge search failed.")
        }
        return .finish(answer: "Knowledge observation received through ToolRuntime.")
    }
}
