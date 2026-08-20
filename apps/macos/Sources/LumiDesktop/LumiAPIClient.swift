import Foundation

struct LumiAPIClient: Sendable {
    enum ClientError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case malformedEvent

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Lumi Core returned an invalid response."
            case .httpStatus(let status):
                return "Lumi Core returned HTTP \(status)."
            case .malformedEvent:
                return "Lumi Core returned a malformed streaming event."
            }
        }
    }

    let baseURL: URL

    init(baseURL: URL = URL(string: "http://127.0.0.1:8790")!) {
        self.baseURL = baseURL
    }

    func health() async throws -> HealthResponse {
        let (data, response) = try await URLSession.shared.data(from: endpoint("health"))
        try validate(response)
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    func runtimeStatus() async throws -> RuntimeStatusResponse {
        let (data, response) = try await URLSession.shared.data(from: endpoint("v1", "runtime"))
        try validate(response)
        return try JSONDecoder().decode(RuntimeStatusResponse.self, from: data)
    }

    func streamChat(message: String, conversationID: String?) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: endpoint("v1", "chat", "stream"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(
                        ChatRequestDTO(message: message, conversationID: conversationID)
                    )

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try validate(response)

                    var dataLines: [String] = []
                    let decoder = JSONDecoder()

                    func flush() throws {
                        guard !dataLines.isEmpty else { return }
                        guard let data = dataLines.joined(separator: "\n").data(using: .utf8) else {
                            throw ClientError.malformedEvent
                        }
                        let event = try decoder.decode(ChatStreamEvent.self, from: data)
                        continuation.yield(event)
                        dataLines.removeAll(keepingCapacity: true)
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            throw CancellationError()
                        }
                        if line.isEmpty {
                            try flush()
                            continue
                        }
                        if line.hasPrefix("data:") {
                            let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            dataLines.append(value)
                        }
                    }
                    try flush()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func cancelGeneration(_ generationID: String) async throws {
        var request = URLRequest(url: endpoint("v1", "generations", generationID, "cancel"))
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    private func endpoint(_ components: String...) -> URL {
        components.reduce(baseURL) { partial, component in
            partial.appendingPathComponent(component)
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.httpStatus(http.statusCode)
        }
    }
}
