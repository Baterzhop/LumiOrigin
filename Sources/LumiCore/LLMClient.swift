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
    func complete(
        messages: [ChatMessage],
        systemPrompt: String,
        profile: PromptProfile
    ) async throws -> String
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

    public func complete(
        messages: [ChatMessage],
        systemPrompt: String,
        profile: PromptProfile
    ) async throws -> String {
        struct WireMessage: Codable {
            let role: String
            let content: String
        }
        struct Options: Codable {
            let temperature: Double
            let top_p: Double
            let num_predict: Int
        }
        struct RequestBody: Codable {
            let model: String
            let messages: [WireMessage]
            let stream: Bool
            let options: Options
        }
        struct ResponseBody: Codable {
            struct ResponseMessage: Codable { let content: String }
            let message: ResponseMessage?
        }

        let wireMessages = [WireMessage(role: "system", content: systemPrompt)] + messages.map {
            WireMessage(role: $0.role.rawValue, content: $0.content)
        }
        let payload = RequestBody(
            model: model,
            messages: wireMessages,
            stream: false,
            options: Options(
                temperature: profile.temperature,
                top_p: profile.topP,
                num_predict: profile.maxTokens
            )
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw LLMError.httpStatus(http.statusCode) }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        let content = decoded.message?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else { throw LLMError.emptyResponse }
        return content
    }
}

public struct LocalFallbackClient: LLMClient, Sendable {
    public init() {}

    public func complete(
        messages: [ChatMessage],
        systemPrompt: String,
        profile: PromptProfile
    ) async throws -> String {
        let prompt = messages.last(where: { $0.role == .user })?.content ?? ""
        if prompt.isEmpty {
            return "Lumi is ready."
        }
        return "Local model is unavailable. I received: \"\(prompt)\". Start Ollama or configure LUMI_OLLAMA_URL to enable generated answers."
    }
}

public struct ResilientLLMClient: LLMClient, Sendable {
    private let primary: any LLMClient
    private let fallback: any LLMClient

    public init(primary: any LLMClient, fallback: any LLMClient = LocalFallbackClient()) {
        self.primary = primary
        self.fallback = fallback
    }

    public func complete(
        messages: [ChatMessage],
        systemPrompt: String,
        profile: PromptProfile
    ) async throws -> String {
        do {
            return try await primary.complete(messages: messages, systemPrompt: systemPrompt, profile: profile)
        } catch {
            return try await fallback.complete(messages: messages, systemPrompt: systemPrompt, profile: profile)
        }
    }
}
