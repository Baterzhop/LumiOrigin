import SwiftUI
import LumiClientCore

struct LumiSettingsView: View {
    private static let initialModelSettings = LumiModelConfiguration.current()

    @State private var coreURL = LumiClientConfiguration.defaultBaseURL().absoluteString
    @State private var apiKey = ""
    @State private var modelServerURL = initialModelSettings.serverURL.absoluteString
    @State private var chatModel = initialModelSettings.chatModel
    @State private var embeddingModel = initialModelSettings.embeddingModel
    @State private var denseRetrievalEnabled = initialModelSettings.denseRetrievalEnabled
    @State private var installedModels: [OllamaInstalledModel] = []

    @State private var status = LumiClientConfiguration.hasStoredAPIKey()
        ? "An API key is stored in Keychain."
        : "No API key is stored. Local loopback mode does not require one."
    @State private var modelStatus = "Discover installed models to verify your local Ollama setup."
    @State private var isTesting = false
    @State private var isDiscoveringModels = false
    @State private var isApplyingModels = false

    var body: some View {
        Form {
            Section("Lumi Core") {
                TextField("Core URL", text: $coreURL)
                    .textFieldStyle(.roundedBorder)
                Text("HTTP is accepted only for localhost. Remote Core connections must use HTTPS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Authentication") {
                SecureField("New API key (leave blank to keep current)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Remote/LAN access requires a Core API key of at least 24 characters. Keys are stored in macOS Keychain, not UserDefaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Remove stored API key", role: .destructive) {
                    do {
                        try LumiClientConfiguration.deleteAPIKey()
                        apiKey = ""
                        status = "Stored API key removed."
                    } catch {
                        status = error.localizedDescription
                    }
                }
                .disabled(!LumiClientConfiguration.hasStoredAPIKey())
            }

            Section("Local model · Ollama") {
                TextField("Ollama server URL", text: $modelServerURL)
                    .textFieldStyle(.roundedBorder)

                TextField("Chat model", text: $chatModel)
                    .textFieldStyle(.roundedBorder)

                TextField("Embedding model", text: $embeddingModel)
                    .textFieldStyle(.roundedBorder)

                Toggle("Dense retrieval / embeddings", isOn: $denseRetrievalEnabled)

                if !installedModels.isEmpty {
                    Picker("Installed chat model", selection: $chatModel) {
                        if !installedModels.contains(where: { $0.name == chatModel }) {
                            Text(chatModel).tag(chatModel)
                        }
                        ForEach(installedModels) { model in
                            Text(modelLabel(model)).tag(model.name)
                        }
                    }

                    Picker("Installed embedding model", selection: $embeddingModel) {
                        if !installedModels.contains(where: { $0.name == embeddingModel }) {
                            Text(embeddingModel).tag(embeddingModel)
                        }
                        ForEach(installedModels) { model in
                            Text(modelLabel(model)).tag(model.name)
                        }
                    }
                }

                HStack {
                    Button("Discover installed models") { discoverModels() }
                        .disabled(isDiscoveringModels)
                    if isDiscoveringModels { ProgressView().controlSize(.small) }
                }

                Text(modelStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Text("These settings configure only the app-managed local Core. Explicit LUMI_OLLAMA_* environment variables continue to override saved values. A remote/external Core keeps its own model configuration.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Connection and runtime") {
                Text(status)
                    .font(.caption)
                    .textSelection(.enabled)
                HStack {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                    Button("Save models & restart managed Core") { saveModelsAndRestart() }
                        .disabled(isApplyingModels)
                    Button("Test Core connection") { testConnection() }
                        .disabled(isTesting)
                    if isTesting || isApplyingModels { ProgressView().controlSize(.small) }
                }
                Text("Model changes can be applied by restarting the Core process owned by Lumi. Changing the Core URL or authentication still requires restarting the Lumi app so existing views rebuild their client connection.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(18)
        .frame(width: 680, height: 690)
    }

    private func save() {
        do {
            try saveConnectionSettings()
            _ = try saveModelSettings()
            status = LumiClientConfiguration.hasStoredAPIKey()
                ? "Saved. API key is stored in Keychain."
                : "Saved. Local loopback mode has no API key."
            modelStatus = "Model settings saved. Restart the managed Core to apply them."
        } catch {
            status = error.localizedDescription
        }
    }

    private func saveModelsAndRestart() {
        guard !isApplyingModels else { return }
        do {
            _ = try saveModelSettings()
        } catch {
            modelStatus = error.localizedDescription
            return
        }

        isApplyingModels = true
        modelStatus = "Restarting the Core process owned by Lumi…"
        Task { @MainActor in
            await CoreProcessManager.shared.restart()
            modelStatus = CoreProcessManager.shared.detail
            isApplyingModels = false
        }
    }

    private func discoverModels() {
        guard !isDiscoveringModels else { return }
        let server: URL
        do {
            server = try LumiModelConfiguration.validatedServerURL(modelServerURL)
        } catch {
            modelStatus = error.localizedDescription
            return
        }

        isDiscoveringModels = true
        modelStatus = "Querying Ollama /api/tags…"
        Task {
            defer { isDiscoveringModels = false }
            do {
                let models = try await OllamaModelDiscoveryClient(baseURL: server).listModels()
                installedModels = models
                if models.isEmpty {
                    modelStatus = "Ollama responded, but no installed models were reported. Install a chat model before real-model acceptance."
                } else {
                    modelStatus = "Ollama reported \(models.count) installed model(s). Select one or keep a custom model name."
                }
            } catch {
                installedModels = []
                modelStatus = "Could not query Ollama: \(error.localizedDescription)"
            }
        }
    }

    private func testConnection() {
        isTesting = true
        status = "Testing connection and authentication…"
        Task {
            defer { isTesting = false }
            do {
                let url = try LumiClientConfiguration.validatedBaseURL(coreURL)
                let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                let client = LumiAPIClient(
                    baseURL: url,
                    apiKey: key.isEmpty ? LumiClientConfiguration.defaultAPIKey() : key
                )
                let health = try await client.health()
                let runtime = try await client.runtimeStatus()
                status = health.ok && runtime.ok
                    ? "Connection and authentication successful: Lumi Core \(health.version), model \(runtime.model)."
                    : "Core responded but did not report ready runtime state."
            } catch {
                status = "Connection/authentication failed: \(error.localizedDescription)"
            }
        }
    }

    private func saveConnectionSettings() throws {
        try LumiClientConfiguration.saveBaseURL(coreURL)
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try LumiClientConfiguration.saveAPIKey(apiKey)
            apiKey = ""
        }
    }

    private func saveModelSettings() throws -> LumiManagedModelSettings {
        try LumiModelConfiguration.save(
            serverURL: modelServerURL,
            chatModel: chatModel,
            embeddingModel: embeddingModel,
            denseRetrievalEnabled: denseRetrievalEnabled
        )
    }

    private func modelLabel(_ model: OllamaInstalledModel) -> String {
        guard let size = model.size, size > 0 else { return model.name }
        return "\(model.name) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }
}
