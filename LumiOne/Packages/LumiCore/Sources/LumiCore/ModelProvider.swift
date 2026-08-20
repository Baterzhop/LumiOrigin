import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ModelRequest: Sendable {
    public let messages: [ChatMessage]

    public init(messages: [ChatMessage]) {
        self.messages = messages
    }
}

public struct ModelResponse: Sendable {
    public let content: String

    public init(content: String) {
        self.content = content
    }
}

public protocol ModelProvider: Sendable {
    func respond(to request: ModelRequest) async throws -> ModelResponse
}

public enum ModelProviderError: Error, CustomStringConvertible, Sendable {
    case invalidResponse
    case server(status: Int, body: String)
    case emptyResponse

    public var description: String {
        switch self {
        case .invalidResponse:
            return "Model server returned an invalid response."
        case .server(let status, let body):
            return "Model server returned HTTP \(status): \(body)"
        case .emptyResponse:
            return "Model server returned no assistant content."
        }
    }
}

public struct OpenAICompatibleProvider: ModelProvider, Sendable {
    public let endpoint: URL
    public let model: String
    public let systemPrompt: String

    public init(
        endpoint: URL = URL(string: "http://127.0.0.1:8080/v1/chat/completions")!,
        model: String = "local",
        systemPrompt: String = "You are Lumi, a precise local personal AI assistant."
    ) {
        self.endpoint = endpoint
        self.model = model
        self.systemPrompt = systemPrompt
    }

    public func respond(to request: ModelRequest) async throws -> ModelResponse {
        var apiMessages = [APIMessage(role: "system", content: systemPrompt)]
        apiMessages.append(contentsOf: request.messages.compactMap { message in
            let role: String
            switch message.role {
            case .system: role = "system"
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .tool: role = "tool"
            }
            return APIMessage(role: role, content: message.content)
        })

        let payload = RequestBody(model: model, messages: apiMessages, stream: false)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 120
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelProviderError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ModelProviderError.server(
                status: httpResponse.statusCode,
                body: String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"
            )
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw ModelProviderError.emptyResponse
        }

        return ModelResponse(content: content)
    }
}

private struct RequestBody: Encodable {
    let model: String
    let messages: [APIMessage]
    let stream: Bool
}

private struct ResponseBody: Decodable {
    let choices: [Choice]
}

private struct Choice: Decodable {
    let message: APIMessage
}

private struct APIMessage: Codable {
    let role: String
    let content: String
}
