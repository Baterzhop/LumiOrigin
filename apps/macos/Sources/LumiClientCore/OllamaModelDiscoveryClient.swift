import Foundation

public struct OllamaInstalledModel: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let model: String?
    public let size: Int64?

    public var id: String { name }
}

struct OllamaTagsResponse: Codable, Equatable {
    let models: [OllamaInstalledModel]
}

public struct OllamaModelDiscoveryClient {
    public typealias Loader = (URLRequest) async throws -> (Data, URLResponse)

    public let baseURL: URL
    private let loader: Loader

    public init(
        baseURL: URL,
        loader: @escaping Loader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.baseURL = baseURL
        self.loader = loader
    }

    public func listModels() async throws -> [OllamaInstalledModel] {
        let url = baseURL.appendingPathComponent("api").appendingPathComponent("tags")
        let (data, response) = try await loader(URLRequest(url: url))
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try Self.decodeModels(data)
    }

    static func decodeModels(_ data: Data) throws -> [OllamaInstalledModel] {
        let payload = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        var seen = Set<String>()
        return payload.models
            .filter { !$0.name.isEmpty && seen.insert($0.name).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
