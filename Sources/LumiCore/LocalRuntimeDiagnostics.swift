import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LocalModelConfiguration: Hashable, Sendable {
    public let chatEndpoint: URL
    public let embeddingEndpoint: URL
    public let tagsEndpoint: URL
    public let roleModels: [ModelRole: String]
    public let embeddingModel: String
    public let contextWindow: Int

    public init(
        chatEndpoint: URL,
        embeddingEndpoint: URL,
        tagsEndpoint: URL,
        roleModels: [ModelRole: String],
        embeddingModel: String,
        contextWindow: Int = 8_192
    ) {
        let chatModel = roleModels[.chat]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.chatEndpoint = chatEndpoint
        self.embeddingEndpoint = embeddingEndpoint
        self.tagsEndpoint = tagsEndpoint
        self.roleModels = [
            .chat: Self.nonEmpty(chatModel) ?? "llama3.2",
            .knowledge: Self.nonEmpty(roleModels[.knowledge]) ?? Self.nonEmpty(chatModel) ?? "llama3.2",
            .coding: Self.nonEmpty(roleModels[.coding]) ?? Self.nonEmpty(chatModel) ?? "llama3.2",
            .reflection: Self.nonEmpty(roleModels[.reflection]) ?? Self.nonEmpty(chatModel) ?? "llama3.2",
            .agentPlanner: Self.nonEmpty(roleModels[.agentPlanner]) ?? Self.nonEmpty(chatModel) ?? "llama3.2"
        ]
        self.embeddingModel = Self.nonEmpty(embeddingModel) ?? "nomic-embed-text"
        self.contextWindow = max(1_024, contextWindow)
    }

    public func model(for role: ModelRole) -> String {
        roleModels[role] ?? roleModels[.chat] ?? "llama3.2"
    }

    public static func environment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LocalModelConfiguration {
        let defaultChatURL = URL(string: "http://127.0.0.1:11434/api/chat")!
        let defaultEmbeddingURL = URL(string: "http://127.0.0.1:11434/api/embed")!
        let chatEndpoint = Self.url(environment["LUMI_OLLAMA_URL"]) ?? defaultChatURL
        let embeddingEndpoint = Self.url(environment["LUMI_OLLAMA_EMBED_URL"]) ?? defaultEmbeddingURL

        let defaultTags = chatEndpoint
            .deletingLastPathComponent()
            .appendingPathComponent("tags")
        let tagsEndpoint = Self.url(environment["LUMI_OLLAMA_TAGS_URL"]) ?? defaultTags

        let base = Self.nonEmpty(environment["LUMI_OLLAMA_MODEL"]) ?? "llama3.2"
        let chat = Self.nonEmpty(environment["LUMI_OLLAMA_CHAT_MODEL"]) ?? base
        let knowledge = Self.nonEmpty(environment["LUMI_OLLAMA_KNOWLEDGE_MODEL"]) ?? chat
        let coding = Self.nonEmpty(environment["LUMI_OLLAMA_CODING_MODEL"]) ?? chat
        let reflection = Self.nonEmpty(environment["LUMI_OLLAMA_REFLECTION_MODEL"]) ?? chat
        let agent = Self.nonEmpty(environment["LUMI_OLLAMA_AGENT_MODEL"]) ?? chat
        let embedding = Self.nonEmpty(environment["LUMI_EMBED_MODEL"]) ?? "nomic-embed-text"
        let contextWindow = Int(environment["LUMI_CONTEXT_WINDOW"] ?? "") ?? 8_192

        return LocalModelConfiguration(
            chatEndpoint: chatEndpoint,
            embeddingEndpoint: embeddingEndpoint,
            tagsEndpoint: tagsEndpoint,
            roleModels: [
                .chat: chat,
                .knowledge: knowledge,
                .coding: coding,
                .reflection: reflection,
                .agentPlanner: agent
            ],
            embeddingModel: embedding,
            contextWindow: contextWindow
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func url(_ value: String?) -> URL? {
        guard let value = nonEmpty(value) else { return nil }
        return URL(string: value)
    }
}

public protocol OllamaModelInventoryProviding: Sendable {
    func installedModels() async throws -> [String]
}

public struct OllamaModelInventoryClient: OllamaModelInventoryProviding, Sendable {
    private let endpoint: URL
    private let timeout: TimeInterval

    public init(endpoint: URL, timeout: TimeInterval = 4) {
        self.endpoint = endpoint
        self.timeout = max(1, min(timeout, 30))
    }

    public func installedModels() async throws -> [String] {
        struct Response: Decodable {
            struct Model: Decodable {
                let name: String?
                let model: String?
            }
            let models: [Model]?
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LumiRuntimeError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw LumiRuntimeError.providerUnavailable("Ollama HTTP \(http.statusCode)")
            }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let values = (decoded.models ?? []).flatMap { model -> [String] in
                [model.name, model.model].compactMap { value in
                    guard let value else { return nil }
                    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return clean.isEmpty ? nil : clean
                }
            }
            return Array(Set(values)).sorted()
        } catch let error as LumiRuntimeError {
            throw error
        } catch {
            throw LumiRuntimeError.providerUnavailable(error.localizedDescription)
        }
    }
}

public enum LocalRuntimeReadiness: String, Codable, Hashable, Sendable {
    case ready
    case degraded
    case unavailable
}

public struct RuntimeModelDiagnostic: Identifiable, Codable, Hashable, Sendable {
    public let role: ModelRole
    public let configuredModel: String
    public let installed: Bool
    public let usesChatFallbackWhenMissing: Bool

    public var id: String { role.rawValue }

    public init(
        role: ModelRole,
        configuredModel: String,
        installed: Bool,
        usesChatFallbackWhenMissing: Bool
    ) {
        self.role = role
        self.configuredModel = configuredModel
        self.installed = installed
        self.usesChatFallbackWhenMissing = usesChatFallbackWhenMissing
    }
}

public struct LocalRuntimeDiagnosticReport: Codable, Hashable, Sendable {
    public let readiness: LocalRuntimeReadiness
    public let ollamaReachable: Bool
    public let modelRoutes: [RuntimeModelDiagnostic]
    public let embeddingModel: String
    public let embeddingInstalled: Bool
    public let installedModels: [String]
    public let chatEndpoint: String
    public let embeddingEndpoint: String
    public let tagsEndpoint: String
    public let contextWindow: Int
    public let databasePath: String?
    public let workspacePath: String?
    public let issue: String?
    public let checkedAt: Date

    public init(
        readiness: LocalRuntimeReadiness,
        ollamaReachable: Bool,
        modelRoutes: [RuntimeModelDiagnostic],
        embeddingModel: String,
        embeddingInstalled: Bool,
        installedModels: [String],
        chatEndpoint: String,
        embeddingEndpoint: String,
        tagsEndpoint: String,
        contextWindow: Int,
        databasePath: String? = nil,
        workspacePath: String? = nil,
        issue: String? = nil,
        checkedAt: Date = Date()
    ) {
        self.readiness = readiness
        self.ollamaReachable = ollamaReachable
        self.modelRoutes = modelRoutes
        self.embeddingModel = embeddingModel
        self.embeddingInstalled = embeddingInstalled
        self.installedModels = installedModels
        self.chatEndpoint = chatEndpoint
        self.embeddingEndpoint = embeddingEndpoint
        self.tagsEndpoint = tagsEndpoint
        self.contextWindow = contextWindow
        self.databasePath = databasePath
        self.workspacePath = workspacePath
        self.issue = issue
        self.checkedAt = checkedAt
    }
}

public struct LocalRuntimeDiagnosticService: Sendable {
    private let configuration: LocalModelConfiguration
    private let inventory: any OllamaModelInventoryProviding
    private let databasePath: String?
    private let workspacePath: String?

    public init(
        configuration: LocalModelConfiguration,
        inventory: any OllamaModelInventoryProviding,
        databasePath: String? = nil,
        workspacePath: String? = nil
    ) {
        self.configuration = configuration
        self.inventory = inventory
        self.databasePath = databasePath
        self.workspacePath = workspacePath
    }

    public static func environment(
        databaseURL: URL = SQLiteConversationStore.defaultDatabaseURL(),
        workspaceURL: URL? = nil
    ) -> LocalRuntimeDiagnosticService {
        let configuration = LocalModelConfiguration.environment()
        let resolvedWorkspace = workspaceURL ?? LumiEngine.defaultWorkspaceURL(databaseURL: databaseURL)
        return LocalRuntimeDiagnosticService(
            configuration: configuration,
            inventory: OllamaModelInventoryClient(endpoint: configuration.tagsEndpoint),
            databasePath: databaseURL.path,
            workspacePath: resolvedWorkspace.path
        )
    }

    public func check() async -> LocalRuntimeDiagnosticReport {
        do {
            let installed = try await inventory.installedModels()
            return Self.report(
                configuration: configuration,
                installedModels: installed,
                databasePath: databasePath,
                workspacePath: workspacePath,
                issue: nil
            )
        } catch {
            return Self.unavailableReport(
                configuration: configuration,
                databasePath: databasePath,
                workspacePath: workspacePath,
                issue: error.localizedDescription
            )
        }
    }

    public static func report(
        configuration: LocalModelConfiguration,
        installedModels: [String],
        databasePath: String? = nil,
        workspacePath: String? = nil,
        issue: String? = nil,
        checkedAt: Date = Date()
    ) -> LocalRuntimeDiagnosticReport {
        let installed = Array(Set(installedModels)).sorted()
        let chatModel = configuration.model(for: .chat)
        let chatInstalled = isInstalled(chatModel, installedModels: installed)

        let roles: [ModelRole] = [.chat, .knowledge, .coding, .reflection, .agentPlanner]
        let routeDiagnostics = roles.map { role in
            let model = configuration.model(for: role)
            return RuntimeModelDiagnostic(
                role: role,
                configuredModel: model,
                installed: isInstalled(model, installedModels: installed),
                usesChatFallbackWhenMissing: role != .chat && model != chatModel
            )
        }
        let embeddingInstalled = isInstalled(configuration.embeddingModel, installedModels: installed)
        let specializedMissing = routeDiagnostics.contains {
            $0.role != .chat && !$0.installed && $0.configuredModel != chatModel
        }

        let readiness: LocalRuntimeReadiness
        if !chatInstalled {
            readiness = .unavailable
        } else if specializedMissing || !embeddingInstalled {
            readiness = .degraded
        } else {
            readiness = .ready
        }

        return LocalRuntimeDiagnosticReport(
            readiness: readiness,
            ollamaReachable: true,
            modelRoutes: routeDiagnostics,
            embeddingModel: configuration.embeddingModel,
            embeddingInstalled: embeddingInstalled,
            installedModels: installed,
            chatEndpoint: configuration.chatEndpoint.absoluteString,
            embeddingEndpoint: configuration.embeddingEndpoint.absoluteString,
            tagsEndpoint: configuration.tagsEndpoint.absoluteString,
            contextWindow: configuration.contextWindow,
            databasePath: databasePath,
            workspacePath: workspacePath,
            issue: issue,
            checkedAt: checkedAt
        )
    }

    public static func unavailableReport(
        configuration: LocalModelConfiguration,
        databasePath: String? = nil,
        workspacePath: String? = nil,
        issue: String,
        checkedAt: Date = Date()
    ) -> LocalRuntimeDiagnosticReport {
        let chatModel = configuration.model(for: .chat)
        let roles: [ModelRole] = [.chat, .knowledge, .coding, .reflection, .agentPlanner]
        return LocalRuntimeDiagnosticReport(
            readiness: .unavailable,
            ollamaReachable: false,
            modelRoutes: roles.map { role in
                let model = configuration.model(for: role)
                return RuntimeModelDiagnostic(
                    role: role,
                    configuredModel: model,
                    installed: false,
                    usesChatFallbackWhenMissing: role != .chat && model != chatModel
                )
            },
            embeddingModel: configuration.embeddingModel,
            embeddingInstalled: false,
            installedModels: [],
            chatEndpoint: configuration.chatEndpoint.absoluteString,
            embeddingEndpoint: configuration.embeddingEndpoint.absoluteString,
            tagsEndpoint: configuration.tagsEndpoint.absoluteString,
            contextWindow: configuration.contextWindow,
            databasePath: databasePath,
            workspacePath: workspacePath,
            issue: issue,
            checkedAt: checkedAt
        )
    }

    public static func isInstalled(_ configuredModel: String, installedModels: [String]) -> Bool {
        let configured = configuredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty else { return false }
        if installedModels.contains(configured) { return true }
        if !configured.contains(":"), installedModels.contains(configured + ":latest") {
            return true
        }
        return false
    }
}
