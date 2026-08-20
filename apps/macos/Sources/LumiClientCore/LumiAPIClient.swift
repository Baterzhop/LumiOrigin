import Foundation

public struct LumiAPIClient: Sendable {
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

    public let baseURL: URL

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8790")!) {
        self.baseURL = baseURL
    }

    public func health() async throws -> HealthResponse {
        let (data, response) = try await URLSession.shared.data(from: endpoint("health"))
        try validate(response)
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    public func runtimeStatus() async throws -> RuntimeStatusResponse {
        let (data, response) = try await URLSession.shared.data(from: endpoint("v1", "runtime"))
        try validate(response)
        return try JSONDecoder().decode(RuntimeStatusResponse.self, from: data)
    }

    public func knowledgeDocuments() async throws -> [KnowledgeDocumentDTO] {
        let (data, response) = try await URLSession.shared.data(from: endpoint("v1", "knowledge", "documents"))
        try validate(response)
        return try JSONDecoder().decode(KnowledgeDocumentsResponse.self, from: data).documents
    }

    public func uploadKnowledge(fileURL: URL) async throws -> KnowledgeUploadResponse {
        let fileData = try Data(contentsOf: fileURL)
        let boundary = "LumiBoundary-\(UUID().uuidString)"
        var body = Data()

        func append(_ string: String) {
            body.append(contentsOf: string.utf8)
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint("v1", "knowledge", "upload"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(KnowledgeUploadResponse.self, from: data)
    }

    public func memories() async throws -> [MemoryRecordDTO] {
        let (data, response) = try await URLSession.shared.data(from: endpoint("v1", "memories"))
        try validate(response)
        return try JSONDecoder().decode(MemoriesResponse.self, from: data).memories
    }

    public func createMemory(content: String, kind: String = "fact", title: String? = nil) async throws -> MemoryRecordDTO {
        let payload = MemoryCreateRequestDTO(content: content, kind: kind, title: title, approvedByUser: true)
        let envelope = try await postJSON(endpoint("v1", "memories"), body: payload, response: MemoryEnvelopeResponse.self)
        return envelope.memory
    }

    public func updateMemory(
        _ memoryID: String,
        content: String? = nil,
        kind: String? = nil,
        title: String? = nil
    ) async throws -> MemoryRecordDTO {
        let payload = MemoryUpdateRequestDTO(content: content, kind: kind, title: title)
        let envelope = try await sendJSON(
            endpoint("v1", "memories", memoryID),
            method: "PATCH",
            body: payload,
            response: MemoryEnvelopeResponse.self
        )
        return envelope.memory
    }

    public func deleteMemory(_ memoryID: String) async throws {
        var request = URLRequest(url: endpoint("v1", "memories", memoryID))
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    public func createTask(
        goal: String,
        conversationID: String?,
        maxSteps: Int = 8,
        maxToolCalls: Int = 6,
        maxSeconds: Int = 120
    ) async throws -> AgentTaskDTO {
        let payload = TaskCreateRequestDTO(
            goal: goal,
            conversationID: conversationID,
            maxSteps: maxSteps,
            maxToolCalls: maxToolCalls,
            maxSeconds: maxSeconds
        )
        return try await postJSON(endpoint("v1", "tasks"), body: payload, response: AgentTaskDTO.self)
    }

    public func task(_ taskID: String) async throws -> AgentTaskDTO {
        let (data, response) = try await URLSession.shared.data(from: endpoint("v1", "tasks", taskID))
        try validate(response)
        return try JSONDecoder().decode(AgentTaskDTO.self, from: data)
    }

    public func approveToolCall(_ toolCallID: String) async throws -> AgentTaskDTO {
        try await postEmpty(endpoint("v1", "tool-calls", toolCallID, "approve"), response: AgentTaskDTO.self)
    }

    public func denyToolCall(_ toolCallID: String) async throws -> AgentTaskDTO {
        try await postEmpty(endpoint("v1", "tool-calls", toolCallID, "deny"), response: AgentTaskDTO.self)
    }

    public func streamChat(message: String, conversationID: String?) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: endpoint("v1", "chat", "stream"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(ChatRequestDTO(message: message, conversationID: conversationID))

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
                        if Task.isCancelled { throw CancellationError() }
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
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func cancelGeneration(_ generationID: String) async throws {
        var request = URLRequest(url: endpoint("v1", "generations", generationID, "cancel"))
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    private func postJSON<Body: Encodable, Response: Decodable>(
        _ url: URL,
        body: Body,
        response: Response.Type
    ) async throws -> Response {
        try await sendJSON(url, method: "POST", body: body, response: response)
    }

    private func sendJSON<Body: Encodable, Response: Decodable>(
        _ url: URL,
        method: String,
        body: Body,
        response: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        try validate(urlResponse)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func postEmpty<Response: Decodable>(_ url: URL, response: Response.Type) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        try validate(urlResponse)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func endpoint(_ components: String...) -> URL {
        components.reduce(baseURL) { partial, component in partial.appendingPathComponent(component) }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.httpStatus(http.statusCode) }
    }
}
