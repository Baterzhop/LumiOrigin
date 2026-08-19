import Foundation

public struct PromptRegistry: Sendable {
    private struct FilePayload: Decodable {
        let profiles: [String: PromptProfile]
    }

    private let profiles: [String: PromptProfile]

    public init(profiles: [String: PromptProfile] = PromptRegistry.defaultProfiles) {
        self.profiles = profiles
    }

    public init(jsonData: Data) throws {
        let payload = try JSONDecoder().decode(FilePayload.self, from: jsonData)
        self.profiles = payload.profiles
    }

    public static func bundled() -> PromptRegistry {
        guard
            let url = Bundle.module.url(forResource: "prompts", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let registry = try? PromptRegistry(jsonData: data)
        else {
            return PromptRegistry()
        }
        return registry
    }

    public func profile(named name: String?) -> PromptProfile {
        if let name, let profile = profiles[name] {
            return profile
        }
        return profiles["chat"] ?? PromptRegistry.defaultProfiles["chat"]!
    }

    public var names: [String] {
        profiles.keys.sorted()
    }

    public static let defaultProfiles: [String: PromptProfile] = [
        "chat": PromptProfile(
            name: "chat",
            system: "You are Lumi, a concise and reliable local-first assistant. State uncertainty instead of inventing facts.",
            temperature: 0.35,
            topP: 0.9,
            maxTokens: 1_024
        ),
        "knowledge": PromptProfile(
            name: "knowledge",
            system: "You are Lumi Knowledge. Prefer supplied context. If the context is insufficient, say so clearly.",
            temperature: 0.15,
            topP: 0.85,
            maxTokens: 900
        ),
        "coding": PromptProfile(
            name: "coding",
            system: "You are Lumi Coding. Produce minimal, correct, maintainable code and call out assumptions that affect correctness.",
            temperature: 0.2,
            topP: 0.9,
            maxTokens: 1_500
        ),
        "reflection": PromptProfile(
            name: "reflection",
            system: "You are Lumi Reflection. Summarize observations and tradeoffs without pretending to have consciousness or emotions.",
            temperature: 0.25,
            topP: 0.9,
            maxTokens: 900
        )
    ]
}
