import Foundation

public struct ModelRoutingPolicy: Sendable {
    public init() {}

    public func role(for request: ModelRequest) -> ModelRole {
        if let explicitRole = request.role {
            return explicitRole
        }

        switch request.profile.name.lowercased() {
        case "knowledge": return .knowledge
        case "coding": return .coding
        case "reflection": return .reflection
        case "agent-planner", "agentplanner", "agent": return .agentPlanner
        default: return .chat
        }
    }
}

/// Routes generation requests by semantic role while preserving the LLMClient contract.
/// Each route may independently wrap its own retry/fallback policy.
public struct ModelRouter: LLMClient, Sendable {
    private let defaultClient: any LLMClient
    private let routes: [ModelRole: any LLMClient]
    private let policy: ModelRoutingPolicy

    public init(
        defaultClient: any LLMClient,
        routes: [ModelRole: any LLMClient] = [:],
        policy: ModelRoutingPolicy = ModelRoutingPolicy()
    ) {
        self.defaultClient = defaultClient
        self.routes = routes
        self.policy = policy
    }

    public func selectedRole(for request: ModelRequest) -> ModelRole {
        policy.role(for: request)
    }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let role = selectedRole(for: request)
        let client = routes[role] ?? defaultClient
        let response = try await client.complete(request)
        return annotate(response, role: role)
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let role = selectedRole(for: request)
        let client = routes[role] ?? defaultClient

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in client.stream(request) {
                        try Task.checkCancellation()
                        switch event {
                        case .token(let token):
                            continuation.yield(.token(token))
                        case .completed(let response):
                            continuation.yield(.completed(annotate(response, role: role)))
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish(throwing: LumiRuntimeError.invalidResponse)
                } catch is CancellationError {
                    continuation.finish(throwing: LumiRuntimeError.cancelled)
                } catch {
                    if Task.isCancelled {
                        continuation.finish(throwing: LumiRuntimeError.cancelled)
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Local-first production policy. All roles use Ollama, but each role may select a different
    /// local model through environment variables without changing engine/UI code.
    public static func localOllamaDefault() -> ModelRouter {
        let environment = ProcessInfo.processInfo.environment
        let baseModel = environment["LUMI_OLLAMA_MODEL"] ?? "llama3.2"
        let chatModel = environment["LUMI_OLLAMA_CHAT_MODEL"] ?? baseModel
        let knowledgeModel = environment["LUMI_OLLAMA_KNOWLEDGE_MODEL"] ?? chatModel
        let codingModel = environment["LUMI_OLLAMA_CODING_MODEL"] ?? chatModel
        let reflectionModel = environment["LUMI_OLLAMA_REFLECTION_MODEL"] ?? chatModel
        let agentModel = environment["LUMI_OLLAMA_AGENT_MODEL"] ?? chatModel

        func client(model: String) -> any LLMClient {
            ResilientLLMClient(primary: OllamaClient(model: model))
        }

        let chat = client(model: chatModel)
        return ModelRouter(
            defaultClient: chat,
            routes: [
                .chat: chat,
                .knowledge: client(model: knowledgeModel),
                .coding: client(model: codingModel),
                .reflection: client(model: reflectionModel),
                .agentPlanner: client(model: agentModel)
            ]
        )
    }

    private func annotate(_ response: ModelResponse, role: ModelRole) -> ModelResponse {
        let metadata = response.runtime
        return ModelResponse(
            content: response.content,
            runtime: RuntimeMetadata(
                provider: metadata.provider,
                model: metadata.model,
                modelRole: role,
                fallbackUsed: metadata.fallbackUsed,
                latencyMs: metadata.latencyMs,
                finishReason: metadata.finishReason,
                usage: metadata.usage
            )
        )
    }
}
