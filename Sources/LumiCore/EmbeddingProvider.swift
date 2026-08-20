import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum EmbeddingError: Error, LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case emptyEmbedding
    case inconsistentDimensions
    case invalidVector

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The embedding provider returned an invalid response."
        case .httpStatus(let code): return "The embedding endpoint returned HTTP \(code)."
        case .emptyEmbedding: return "The embedding provider returned no vectors."
        case .inconsistentDimensions: return "Embedding vectors have inconsistent dimensions."
        case .invalidVector: return "The embedding provider returned a non-finite or empty vector."
        }
    }
}

public protocol EmbeddingProvider: Sendable {
    var modelID: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public struct OllamaEmbeddingProvider: EmbeddingProvider, Sendable {
    public let modelID: String
    private let endpoint: URL
    private let timeout: TimeInterval

    public init(
        endpoint: URL? = nil,
        model: String? = nil,
        timeout: TimeInterval = 60
    ) {
        let environment = ProcessInfo.processInfo.environment
        self.endpoint = endpoint
            ?? URL(string: environment["LUMI_OLLAMA_EMBED_URL"] ?? "http://127.0.0.1:11434/api/embed")!
        self.modelID = model ?? environment["LUMI_EMBED_MODEL"] ?? "nomic-embed-text"
        self.timeout = timeout
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        struct RequestBody: Encodable {
            let model: String
            let input: [String]
        }
        struct ResponseBody: Decodable {
            let embeddings: [[Double]]?
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(model: modelID, input: texts))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EmbeddingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw EmbeddingError.httpStatus(http.statusCode) }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let rawVectors = decoded.embeddings, rawVectors.count == texts.count, !rawVectors.isEmpty else {
            throw EmbeddingError.emptyEmbedding
        }

        let vectors = rawVectors.map { $0.map(Float.init) }
        try Self.validate(vectors)
        return vectors
    }

    private static func validate(_ vectors: [[Float]]) throws {
        guard let dimension = vectors.first?.count, dimension > 0 else {
            throw EmbeddingError.emptyEmbedding
        }

        for vector in vectors {
            guard vector.count == dimension else { throw EmbeddingError.inconsistentDimensions }
            guard !vector.isEmpty, vector.allSatisfy({ $0.isFinite }) else {
                throw EmbeddingError.invalidVector
            }
        }
    }
}
