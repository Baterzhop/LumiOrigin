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
/// A failed specialized route may fall back to the default generation client before that client's
/// own provider fallback policy is applied.
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

        guard let routedClient = routes[role] else {
            return annotate(
                try await defaultClient.complete(request),
                role: role,
                routeFallbackUsed: false
            )
        }

        do {
            return annotate(
                try await routedClient.complete(request),
                role: role,
                routeFallbackUsed: false
            )
        } catch {
            if Task.isCancelled { throw LumiRuntimeError.cancelled }
            return annotate(
                try await defaultClient.complete(request),
                role: role,
                routeFallbackUsed: true
            )
        }
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let role = selectedRole(for: request)
        guard let routedClient = routes[role] else {
            return annotatedStream(
                from: defaultClient,
                request: request,
                role: role,
                routeFallbackUsed: false
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var emittedPrimaryContent = false

                do {
                    for try await event in routedClient.stream(request) {
                        try Task.checkCancellation()
                        switch event {
                        case .token(let token):
                            emittedPrimaryContent = true
                            continuation.yield(.token(token))
                        case .completed(let response):
                            continuation.yield(
                                .completed(
                                    annotate(
                                        response,
                                        role: role,
                                        routeFallbackUsed: false
                                    )
                                )
                            )
                            continuation.finish()
                            return
                        }
                    }

                    if emittedPrimaryContent {
                        throw LumiRuntimeError.invalidResponse
                    }
                } catch {
                    if Task.isCancelled {
                        continuation.finish(throwing: LumiRuntimeError.cancelled)
                        return
                    }

                    // Once partial content from one model has been emitted, switching models could
                    // duplicate or contradict the visible answer. Fail instead of mixing streams.
                    if emittedPrimaryContent {
                        continuation.finish(throwing: error)
                        return
                    }
                }

                do {
                    for try await event in defaultClient.stream(request) {
                        try Task.checkCancellation()
                        switch event {
                        case .token(let token):
                            continuation.yield(.token(token))
                        case .completed(let response):
                            continuation.yield(
                                .completed(
                                    annotate(
                                        response,
                                        role: role,
                                        routeFallbackUsed: true
                                    )
                                )
                            )
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

    /// Local-first production policy. The default chat route has its normal deterministic fallback.
    /// Optional specialized Ollama models fall back to that chat route when unavailable.
    public static func localOllamaDefault() -> ModelRouter {
        let environment = ProcessInfo.processInfo.environment
        let baseModel = environment["LUMI_OLLAMA_MODEL"] ?? "llama3.2"
        let chatModel = environment["LUMI_OLLAMA_CHAT_MODEL"] ?? baseModel
        let knowledgeModel = environment["LUMI_OLLAMA_KNOWLEDGE_MODEL"] ?? chatModel
        let codingModel = environment["LUMI_OLLAMA_CODING_MODEL"] ?? chatModel
        let reflectionModel = environment["LUMI_OLLAMA_REFLECTION_MODEL"] ?? chatModel
        let agentModel = environment["LUMI_OLLAMA_AGENT_MODEL"] ?? chatModel

        let chat: any LLMClient = ResilientLLMClient(
            primary: OllamaClient(model: chatModel)
        )
        var routes: [ModelRole: any LLMClient] = [:]

        func addSpecializedRoute(_ role: ModelRole, model: String) {
            guard model != chatModel else { return }
            routes[role] = OllamaClient(model: model)
        }

        addSpecializedRoute(.knowledge, model: knowledgeModel)
        addSpecializedRoute(.coding, model: codingModel)
        addSpecializedRoute(.reflection, model: reflectionModel)
        addSpecializedRoute(.agentPlanner, model: agentModel)

        return ModelRouter(
            defaultClient: chat,
            routes: routes
        )
    }

    private func annotatedStream(
        from client: any LLMClient,
        request: ModelRequest,
        role: ModelRole,
        routeFallbackUsed: Bool
    ) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in client.stream(request) {
                        try Task.checkCancellation()
                        switch event {
                        case .token(let token):
                            continuation.yield(.token(token))
                        case .completed(let response):
                            continuation.yield(
                                .completed(
                                    annotate(
                                        response,
                                        role: role,
                                        routeFallbackUsed: routeFallbackUsed
                                    )
                                )
                            )
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

    private func annotate(
        _ response: ModelResponse,
        role: ModelRole,
        routeFallbackUsed: Bool
    ) -> ModelResponse {
        let metadata = response.runtime
        return ModelResponse(
            content: response.content,
            runtime: RuntimeMetadata(
                provider: metadata.provider,
                model: metadata.model,
                modelRole: role,
                fallbackUsed: metadata.fallbackUsed || routeFallbackUsed,
                latencyMs: metadata.latencyMs,
                finishReason: metadata.finishReason,
                usage: metadata.usage
            )
        )
    }
}
