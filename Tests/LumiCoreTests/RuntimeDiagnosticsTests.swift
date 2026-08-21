import XCTest
@testable import LumiCore

final class RuntimeDiagnosticsTests: XCTestCase {
    func testEnvironmentConfigurationUsesOneSourceOfTruthForRoutesAndEndpoints() {
        let environment: [String: String] = [
            "LUMI_OLLAMA_URL": "http://localhost:9999/custom/chat",
            "LUMI_OLLAMA_EMBED_URL": "http://localhost:9999/custom/embed",
            "LUMI_OLLAMA_TAGS_URL": "http://localhost:9999/custom/tags",
            "LUMI_OLLAMA_MODEL": "base-model",
            "LUMI_OLLAMA_CHAT_MODEL": "chat-model",
            "LUMI_OLLAMA_CODING_MODEL": "code-model",
            "LUMI_OLLAMA_AGENT_MODEL": "agent-model",
            "LUMI_EMBED_MODEL": "embed-model",
            "LUMI_CONTEXT_WINDOW": "16384"
        ]

        let configuration = LocalModelConfiguration.environment(environment)

        XCTAssertEqual(configuration.chatEndpoint.absoluteString, "http://localhost:9999/custom/chat")
        XCTAssertEqual(configuration.embeddingEndpoint.absoluteString, "http://localhost:9999/custom/embed")
        XCTAssertEqual(configuration.tagsEndpoint.absoluteString, "http://localhost:9999/custom/tags")
        XCTAssertEqual(configuration.model(for: .chat), "chat-model")
        XCTAssertEqual(configuration.model(for: .knowledge), "chat-model")
        XCTAssertEqual(configuration.model(for: .coding), "code-model")
        XCTAssertEqual(configuration.model(for: .reflection), "chat-model")
        XCTAssertEqual(configuration.model(for: .agentPlanner), "agent-model")
        XCTAssertEqual(configuration.embeddingModel, "embed-model")
        XCTAssertEqual(configuration.contextWindow, 16_384)
    }

    func testDefaultTagsEndpointIsDerivedFromChatAPI() {
        let configuration = LocalModelConfiguration.environment([
            "LUMI_OLLAMA_URL": "http://127.0.0.1:11434/api/chat"
        ])

        XCTAssertEqual(configuration.tagsEndpoint.absoluteString, "http://127.0.0.1:11434/api/tags")
    }

    func testReadyReportAcceptsOllamaLatestTagForShorthandModel() {
        let configuration = configuration(
            chat: "llama3.2",
            knowledge: "llama3.2",
            coding: "qwen2.5-coder:7b",
            reflection: "llama3.2",
            agent: "llama3.2",
            embedding: "nomic-embed-text"
        )

        let report = LocalRuntimeDiagnosticService.report(
            configuration: configuration,
            installedModels: [
                "llama3.2:latest",
                "qwen2.5-coder:7b",
                "nomic-embed-text:latest"
            ]
        )

        XCTAssertEqual(report.readiness, .ready)
        XCTAssertTrue(report.ollamaReachable)
        XCTAssertTrue(report.embeddingInstalled)
        XCTAssertTrue(report.modelRoutes.allSatisfy(\.installed))
    }

    func testMissingSpecializedAndEmbeddingModelsProduceDegradedReportWithFallbackMetadata() {
        let configuration = configuration(
            chat: "chat:latest",
            knowledge: "knowledge:7b",
            coding: "code:7b",
            reflection: "chat:latest",
            agent: "agent:7b",
            embedding: "embed:latest"
        )

        let report = LocalRuntimeDiagnosticService.report(
            configuration: configuration,
            installedModels: ["chat:latest"]
        )

        XCTAssertEqual(report.readiness, .degraded)
        XCTAssertFalse(report.embeddingInstalled)
        XCTAssertEqual(report.modelRoutes.first(where: { $0.role == .chat })?.installed, true)
        XCTAssertEqual(report.modelRoutes.first(where: { $0.role == .coding })?.installed, false)
        XCTAssertEqual(report.modelRoutes.first(where: { $0.role == .coding })?.usesChatFallbackWhenMissing, true)
        XCTAssertEqual(report.modelRoutes.first(where: { $0.role == .reflection })?.usesChatFallbackWhenMissing, false)
    }

    func testMissingChatModelMakesRuntimeUnavailableEvenWhenServerResponds() {
        let configuration = configuration(
            chat: "chat:latest",
            knowledge: "chat:latest",
            coding: "chat:latest",
            reflection: "chat:latest",
            agent: "chat:latest",
            embedding: "embed:latest"
        )

        let report = LocalRuntimeDiagnosticService.report(
            configuration: configuration,
            installedModels: ["embed:latest"]
        )

        XCTAssertTrue(report.ollamaReachable)
        XCTAssertEqual(report.readiness, .unavailable)
    }

    func testDiagnosticServiceTurnsInventoryFailureIntoUnavailableReport() async {
        let configuration = configuration(
            chat: "chat:latest",
            knowledge: "chat:latest",
            coding: "chat:latest",
            reflection: "chat:latest",
            agent: "chat:latest",
            embedding: "embed:latest"
        )
        let service = LocalRuntimeDiagnosticService(
            configuration: configuration,
            inventory: FailingInventory(),
            databasePath: "/tmp/lumi.sqlite3",
            workspacePath: "/tmp/workspace"
        )

        let report = await service.check()

        XCTAssertEqual(report.readiness, .unavailable)
        XCTAssertFalse(report.ollamaReachable)
        XCTAssertNotNil(report.issue)
        XCTAssertEqual(report.databasePath, "/tmp/lumi.sqlite3")
        XCTAssertEqual(report.workspacePath, "/tmp/workspace")
    }

    func testDiagnosticReportRedactsCredentialsQueryAndFragmentFromEndpoints() {
        let configuration = LocalModelConfiguration(
            chatEndpoint: URL(string: "http://user:secret@localhost:11434/api/chat?token=abc#private")!,
            embeddingEndpoint: URL(string: "http://user:secret@localhost:11434/api/embed?key=xyz")!,
            tagsEndpoint: URL(string: "http://user:secret@localhost:11434/api/tags?key=xyz")!,
            roleModels: [.chat: "chat:latest"],
            embeddingModel: "embed:latest"
        )

        let report = LocalRuntimeDiagnosticService.report(
            configuration: configuration,
            installedModels: ["chat:latest", "embed:latest"]
        )

        for endpoint in [report.chatEndpoint, report.embeddingEndpoint, report.tagsEndpoint] {
            XCTAssertFalse(endpoint.contains("secret"))
            XCTAssertFalse(endpoint.contains("token="))
            XCTAssertFalse(endpoint.contains("key="))
            XCTAssertFalse(endpoint.contains("private"))
            XCTAssertFalse(endpoint.contains("user@"))
        }
    }

    private func configuration(
        chat: String,
        knowledge: String,
        coding: String,
        reflection: String,
        agent: String,
        embedding: String
    ) -> LocalModelConfiguration {
        LocalModelConfiguration(
            chatEndpoint: URL(string: "http://127.0.0.1:11434/api/chat")!,
            embeddingEndpoint: URL(string: "http://127.0.0.1:11434/api/embed")!,
            tagsEndpoint: URL(string: "http://127.0.0.1:11434/api/tags")!,
            roleModels: [
                .chat: chat,
                .knowledge: knowledge,
                .coding: coding,
                .reflection: reflection,
                .agentPlanner: agent
            ],
            embeddingModel: embedding
        )
    }
}

private struct FailingInventory: OllamaModelInventoryProviding {
    func installedModels() async throws -> [String] {
        throw LumiRuntimeError.providerUnavailable("diagnostic test")
    }
}
