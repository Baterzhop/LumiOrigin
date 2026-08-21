import SwiftUI
import LumiClientCore

struct LumiSetupView: View {
    @ObservedObject var coreManager: CoreProcessManager
    let onComplete: () -> Void

    private static let initial = LumiModelConfiguration.current()

    @State private var serverURL = initial.serverURL.absoluteString
    @State private var chatModel = initial.chatModel
    @State private var embeddingModel = initial.embeddingModel
    @State private var denseRetrieval = initial.denseRetrievalEnabled
    @State private var models: [OllamaInstalledModel] = []
    @State private var status = "Connect to Ollama and choose the models Lumi should use."
    @State private var isDiscovering = false
    @State private var isApplying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Finish Lumi setup")
                    .font(.largeTitle.weight(.semibold))
                Text("Lumi Core is installed. Configure the local model once, then run the machine readiness check.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("1 · Ollama") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Ollama server URL", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Discover installed models") { discover() }
                            .buttonStyle(.borderedProminent)
                            .disabled(isDiscovering || isApplying)
                        if isDiscovering { ProgressView().controlSize(.small) }
                    }
                    Text("Local HTTP is allowed for localhost. Remote model servers must use HTTPS and cannot embed credentials in the URL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("2 · Models") {
                VStack(alignment: .leading, spacing: 10) {
                    if models.isEmpty {
                        TextField("Chat model", text: $chatModel)
                            .textFieldStyle(.roundedBorder)
                        TextField("Embedding model", text: $embeddingModel)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Chat model", selection: $chatModel) {
                            if !models.contains(where: { $0.name == chatModel }) {
                                Text(chatModel).tag(chatModel)
                            }
                            ForEach(models) { model in
                                Text(model.name).tag(model.name)
                            }
                        }
                        Picker("Embedding model", selection: $embeddingModel) {
                            if !models.contains(where: { $0.name == embeddingModel }) {
                                Text(embeddingModel).tag(embeddingModel)
                            }
                            ForEach(models) { model in
                                Text(model.name).tag(model.name)
                            }
                        }
                    }
                    Toggle("Enable dense retrieval / embeddings", isOn: $denseRetrieval)
                    Text("If no embedding model is installed yet, disable dense retrieval. Sparse FTS5 retrieval remains available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Status") {
                HStack(alignment: .top) {
                    if isApplying { ProgressView().controlSize(.small) }
                    Text(status)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Save models and restart Core") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying || isDiscovering)
                Button("Continue in fallback mode") {
                    onComplete()
                }
                .disabled(isApplying)
                Spacer()
                Text("You can change this later in Lumi → Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(minWidth: 760, minHeight: 560)
    }

    private func discover() {
        guard !isDiscovering else { return }
        let server: URL
        do {
            server = try LumiModelConfiguration.validatedServerURL(serverURL)
        } catch {
            status = error.localizedDescription
            return
        }
        isDiscovering = true
        status = "Querying Ollama /api/tags…"
        Task { @MainActor in
            defer { isDiscovering = false }
            do {
                models = try await OllamaModelDiscoveryClient(baseURL: server).listModels()
                if models.isEmpty {
                    status = "Ollama is reachable but reports no installed models. Install a chat model or continue in fallback mode."
                } else {
                    if !models.contains(where: { $0.name == chatModel }), let first = models.first {
                        chatModel = first.name
                    }
                    status = "Found \(models.count) installed model(s). Select the chat model and, if available, an embedding model."
                }
            } catch {
                models = []
                status = "Ollama discovery failed: \(error.localizedDescription)"
            }
        }
    }

    private func apply() {
        guard !isApplying else { return }
        do {
            _ = try LumiModelConfiguration.save(
                serverURL: serverURL,
                chatModel: chatModel,
                embeddingModel: embeddingModel,
                denseRetrievalEnabled: denseRetrieval
            )
        } catch {
            status = error.localizedDescription
            return
        }

        isApplying = true
        status = "Restarting the Core process owned by Lumi with the selected model configuration…"
        Task { @MainActor in
            await coreManager.restart()
            isApplying = false
            switch coreManager.state {
            case .connected, .runningManaged:
                status = "Core is ready with the saved configuration. Continue to Lumi and run Core → Open Readiness Center."
                onComplete()
            default:
                status = coreManager.detail
            }
        }
    }
}
