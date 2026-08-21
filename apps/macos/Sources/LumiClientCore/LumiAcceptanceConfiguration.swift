import Foundation

public struct LumiAcceptanceReport: Codable, Equatable, Sendable {
    public let ok: Bool
    public let baseURL: String
    public let requireModel: Bool
    public let chatProvider: String?
    public let chatModel: String?
    public let fallback: Bool
    public let streamEvents: [String]
    public let repeatableProbe: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case baseURL = "base_url"
        case requireModel = "require_model"
        case chatProvider = "chat_provider"
        case chatModel = "chat_model"
        case fallback
        case streamEvents = "stream_events"
        case repeatableProbe = "repeatable_probe"
    }
}

public enum LumiAcceptanceConfiguration {
    public static func arguments(baseURL: URL, requireModel: Bool) -> [String] {
        var args = ["acceptance", "--base-url", baseURL.absoluteString]
        if requireModel {
            args.append("--require-model")
        }
        return args
    }

    public static func environment(
        existing: [String: String] = ProcessInfo.processInfo.environment,
        apiKey: String?
    ) -> [String: String] {
        var environment = existing
        if let apiKey, !apiKey.isEmpty {
            environment["LUMI_API_KEY"] = apiKey
        } else {
            environment.removeValue(forKey: "LUMI_API_KEY")
        }
        return environment
    }

    public static func decodeReport(_ data: Data) throws -> LumiAcceptanceReport {
        try JSONDecoder().decode(LumiAcceptanceReport.self, from: data)
    }
}
