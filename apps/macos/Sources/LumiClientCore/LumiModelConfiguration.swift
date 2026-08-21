import Foundation

public struct LumiManagedModelSettings: Equatable, Sendable {
    public let serverURL: URL
    public let chatModel: String
    public let embeddingModel: String
    public let denseRetrievalEnabled: Bool

    public init(serverURL: URL, chatModel: String, embeddingModel: String, denseRetrievalEnabled: Bool) {
        self.serverURL = serverURL
        self.chatModel = chatModel
        self.embeddingModel = embeddingModel
        self.denseRetrievalEnabled = denseRetrievalEnabled
    }

    public var chatEndpoint: URL {
        serverURL.appendingPathComponent("api").appendingPathComponent("chat")
    }

    public var embedEndpoint: URL {
        serverURL.appendingPathComponent("api").appendingPathComponent("embed")
    }
}

public enum LumiModelConfiguration {
    public enum ModelConfigurationError: LocalizedError {
        case invalidServerURL
        case insecureRemoteHTTP
        case embeddedCredentials
        case unsupportedURLComponents
        case invalidModelName

        public var errorDescription: String? {
            switch self {
            case .invalidServerURL:
                return "Enter a valid HTTP or HTTPS Ollama server URL."
            case .insecureRemoteHTTP:
                return "Plain HTTP is allowed only for localhost. Use HTTPS for a remote model server."
            case .embeddedCredentials:
                return "Do not place credentials in the Ollama server URL."
            case .unsupportedURLComponents:
                return "The Ollama server URL cannot contain a query string or fragment."
            case .invalidModelName:
                return "Model names must be non-empty and cannot contain whitespace or control characters."
            }
        }
    }

    private static let serverURLKey = "Lumi.Model.OllamaServerURL"
    private static let chatModelKey = "Lumi.Model.ChatModel"
    private static let embeddingModelKey = "Lumi.Model.EmbeddingModel"
    private static let denseRetrievalKey = "Lumi.Model.DenseRetrieval"

    public static let defaultServerURL = URL(string: "http://127.0.0.1:11434")!
    public static let defaultChatModel = "llama3.2"
    public static let defaultEmbeddingModel = "embeddinggemma"

    public static func current() -> LumiManagedModelSettings {
        let defaults = UserDefaults.standard
        let server = defaults.string(forKey: serverURLKey)
            .flatMap { try? validatedServerURL($0) } ?? defaultServerURL
        let chat = validatedStoredModel(defaults.string(forKey: chatModelKey), fallback: defaultChatModel)
        let embedding = validatedStoredModel(defaults.string(forKey: embeddingModelKey), fallback: defaultEmbeddingModel)
        let dense = defaults.object(forKey: denseRetrievalKey) == nil
            ? true
            : defaults.bool(forKey: denseRetrievalKey)
        return LumiManagedModelSettings(
            serverURL: server,
            chatModel: chat,
            embeddingModel: embedding,
            denseRetrievalEnabled: dense
        )
    }

    @discardableResult
    public static func save(
        serverURL: String,
        chatModel: String,
        embeddingModel: String,
        denseRetrievalEnabled: Bool
    ) throws -> LumiManagedModelSettings {
        let server = try validatedServerURL(serverURL)
        let chat = try validatedModelName(chatModel)
        let embedding = try validatedModelName(embeddingModel)
        let settings = LumiManagedModelSettings(
            serverURL: server,
            chatModel: chat,
            embeddingModel: embedding,
            denseRetrievalEnabled: denseRetrievalEnabled
        )
        let defaults = UserDefaults.standard
        defaults.set(server.absoluteString, forKey: serverURLKey)
        defaults.set(chat, forKey: chatModelKey)
        defaults.set(embedding, forKey: embeddingModelKey)
        defaults.set(denseRetrievalEnabled, forKey: denseRetrievalKey)
        return settings
    }

    public static func reset() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: serverURLKey)
        defaults.removeObject(forKey: chatModelKey)
        defaults.removeObject(forKey: embeddingModelKey)
        defaults.removeObject(forKey: denseRetrievalKey)
    }

    public static func managedCoreEnvironment(
        settings: LumiManagedModelSettings = current(),
        existingEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let desired = [
            "LUMI_OLLAMA_URL": settings.chatEndpoint.absoluteString,
            "LUMI_OLLAMA_EMBED_URL": settings.embedEndpoint.absoluteString,
            "LUMI_OLLAMA_MODEL": settings.chatModel,
            "LUMI_EMBEDDING_MODEL": settings.embeddingModel,
            "LUMI_RAG_DENSE": settings.denseRetrievalEnabled ? "true" : "false",
        ]
        return desired.filter { existingEnvironment[$0.key] == nil }
    }

    public static func validatedServerURL(_ value: String) throws -> URL {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: clean),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            throw ModelConfigurationError.invalidServerURL
        }
        if components.user != nil || components.password != nil {
            throw ModelConfigurationError.embeddedCredentials
        }
        if components.query != nil || components.fragment != nil {
            throw ModelConfigurationError.unsupportedURLComponents
        }
        if scheme == "http" && !isLoopbackHost(host) {
            throw ModelConfigurationError.insecureRemoteHTTP
        }
        return url
    }

    public static func validatedModelName(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              clean.count <= 200,
              !clean.unicodeScalars.contains(where: { scalar in
                  CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
              }) else {
            throw ModelConfigurationError.invalidModelName
        }
        return clean
    }

    private static func validatedStoredModel(_ value: String?, fallback: String) -> String {
        guard let value, let clean = try? validatedModelName(value) else { return fallback }
        return clean
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let value = host.lowercased()
        return value == "localhost" || value == "127.0.0.1" || value == "::1" || value == "[::1]"
    }
}
