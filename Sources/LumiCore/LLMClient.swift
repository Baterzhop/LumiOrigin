import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LLMError: Error, LocalizedError, Sendable {
    case invalidResponse
    case emptyResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The model returned an invalid response."
        case .emptyResponse: return "The model returned an empty response."
        case .httpStatus(let code): return "The model endpoint returned HTTP \(code)."
        }
    }
}

public protocol LLMClient: Sendable {
    func complete(_ request: ModelRequest) async throws -> ModelResponse
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
}

public extension LLMClient {
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    try Task.checkCancellation()
                    if !response.content.isEmpty {
                        continuation.yield(.token(response.content))
                    }
                    continuation.yield(.completed(response))
                    continuation.finish()
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
}

private struct OllamaWireMessage: Codable {
    let role: String
    let content: String
}

private struct OllamaOptions: Codable {
    let temperature: Double
    let top_p: Double
    let num_predict: Int
}

private struct OllamaRequestBody: Codable {
    let model: String
    let messages: [OllamaWireMessage]
    let stream: Bool
    let options: OllamaOptions
}

private struct OllamaResponseBody: Codable {
    struct ResponseMessage: Codable {
        let content: String
    }

    let model: String?
    let message: ResponseMessage?
    let done: Bool?
    let done_reason: String?
    let prompt_eval_count: Int?
    let eval_count: Int?
}

public struct OllamaClient: LLMClient, Sendable {
    private let endpoint: URL
    private let model: String
    private let timeout: TimeInterval

    public init(
        endpoint: URL? = nil,
        model: String? = nil,
        timeout: TimeInterval = 45
    ) {
        let environment = ProcessInfo.processInfo.environment
        self.endpoint = endpoint
            ?? URL(string: environment["LUMI_OLLAMA_URL"] ?? "http://127.0.0.1:11434/api/chat")!
        self.model = model ?? environment["LUMI_OLLAMA_MODEL"] ?? "llama3.2"
        self.timeout = timeout
    }

    public func complete(_ modelRequest: ModelRequest) async throws -> ModelResponse {
        let request = try makeURLRequest(modelRequest, stream: false)
        let startedAt = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1_000)

        try validateHTTPResponse(response)

        let decoded: OllamaResponseBody
        do {
            decoded = try JSONDecoder().decode(OllamaResponseBody.self, from: data)
        } catch {
            throw LumiRuntimeError.decodingFailure(error.localizedDescription)
        }

        let content = decoded.message?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else { throw LLMError.emptyResponse }

        return ModelResponse(
            content: content,
            runtime: RuntimeMetadata(
                provider: .ollama,
                model: decoded.model ?? model,
                fallbackUsed: false,
                latencyMs: latencyMs,
                finishReason: finishReason(from: decoded.done_reason),
                usage: ModelUsage(
                    inputTokens: decoded.prompt_eval_count,
                    outputTokens: decoded.eval_count
                )
            )
        )
    }

    public func stream(_ modelRequest: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
#if os(macOS)
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeURLRequest(modelRequest, stream: true)
                    let startedAt = Date()
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try validateHTTPResponse(response)

                    var lineBuffer = Data()
                    var fullContent = ""
                    var responseModel = model
                    var responseUsage = ModelUsage()
                    var responseFinishReason: ModelFinishReason = .unknown

                    func consumeLine(_ rawLine: Data) throws {
                        var line = rawLine
                        if line.last == 13 {
                            line.removeLast()
                        }
                        guard !line.isEmpty else { return }

                        let chunk: OllamaResponseBody
                        do {
                            chunk = try JSONDecoder().decode(OllamaResponseBody.self, from: line)
                        } catch {
                            throw LumiRuntimeError.decodingFailure(error.localizedDescription)
                        }

                        if let modelName = chunk.model, !modelName.isEmpty {
                            responseModel = modelName
                        }

                        let delta = chunk.message?.content ?? ""
                        if !delta.isEmpty {
                            fullContent += delta
                            continuation.yield(.token(delta))
                        }

                        if chunk.done == true {
                            responseFinishReason = finishReason(from: chunk.done_reason)
                            responseUsage = ModelUsage(
                                inputTokens: chunk.prompt_eval_count,
                                outputTokens: chunk.eval_count
                            )
                        }
                    }

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if byte == 10 {
                            try consumeLine(lineBuffer)
                            lineBuffer.removeAll(keepingCapacity: true)
                        } else {
                            lineBuffer.append(byte)
                        }
                    }

                    if !lineBuffer.isEmpty {
                        try consumeLine(lineBuffer)
                    }

                    try Task.checkCancellation()
                    let cleanContent = fullContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanContent.isEmpty else { throw LLMError.emptyResponse }

                    let response = ModelResponse(
                        content: cleanContent,
                        runtime: RuntimeMetadata(
                            provider: .ollama,
                            model: responseModel,
                            fallbackUsed: false,
                            latencyMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                            finishReason: responseFinishReason,
                            usage: responseUsage
                        )
                    )
                    continuation.yield(.completed(response))
                    continuation.finish()
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
#else
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(modelRequest)
                    try Task.checkCancellation()
                    continuation.yield(.token(response.content))
                    continuation.yield(.completed(response))
                    continuation.finish()
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
#endif
    }

    private func makeURLRequest(_ modelRequest: ModelRequest, stream: Bool) throws -> URLRequest {
        let wireMessages = [
            OllamaWireMessage(role: "system", content: modelRequest.systemPrompt)
        ] + modelRequest.messages.map {
            OllamaWireMessage(role: $0.role.rawValue, content: $0.content)
        }

        let payload = OllamaRequestBody(
            model: model,
            messages: wireMessages,
            stream: stream,
            options: OllamaOptions(
                temperature: modelRequest.profile.temperature,
                top_p: modelRequest.profile.topP,
                num_predict: modelRequest.profile.maxTokens
            )
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LumiRuntimeError.invalidResponse
        }

        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw LumiRuntimeError.unauthorized
        case 404:
            throw LumiRuntimeError.modelUnavailable(model)
        case 408:
            throw LumiRuntimeError.timeout
        case 429:
            throw LumiRuntimeError.rateLimited
        default:
            throw LLMError.httpStatus(http.statusCode)
        }
    }

    private func finishReason(from rawValue: String?) -> ModelFinishReason {
        switch rawValue?.lowercased() {
        case "stop": return .stop
        case "length": return .length
        case nil: return .unknown
        default: return .unknown
        }
    }
}

public struct LocalFallbackClient: LLMClient, Sendable {
    public init() {}

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let prompt = request.messages.last(where: { $0.role == .user })?.content ?? ""
        let content: String
        if prompt.isEmpty {
            content = "Lumi is ready."
        } else {
            content = "Local model is unavailable. I received: \"\(prompt)\". Start Ollama or configure LUMI_OLLAMA_URL to enable generated answers."
        }

        return ModelResponse(
            content: content,
            runtime: RuntimeMetadata(
                provider: .localFallback,
                model: "deterministic-fallback",
                fallbackUsed: true,
                latencyMs: 0,
                finishReason: .stop
            )
        )
    }
}

public struct ResilientLLMClient: LLMClient, Sendable {
    private let primary: any LLMClient
    private let fallback: any LLMClient

    public init(primary: any LLMClient, fallback: any LLMClient = LocalFallbackClient()) {
        self.primary = primary
        self.fallback = fallback
    }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        do {
            return try await primary.complete(request)
        } catch {
            if Task.isCancelled {
                throw LumiRuntimeError.cancelled
            }
            return try await fallback.complete(request)
        }
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var emittedPrimaryContent = false

                do {
                    for try await event in primary.stream(request) {
                        try Task.checkCancellation()
                        switch event {
                        case .token(let token):
                            emittedPrimaryContent = true
                            continuation.yield(.token(token))
                        case .completed(let response):
                            continuation.yield(.completed(response))
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

                    if emittedPrimaryContent {
                        continuation.finish(throwing: error)
                        return
                    }
                }

                do {
                    for try await event in fallback.stream(request) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
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
}
