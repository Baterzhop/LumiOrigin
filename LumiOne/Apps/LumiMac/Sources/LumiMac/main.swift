#if canImport(SwiftUI)
import Foundation
import SwiftUI
import LumiCore

@main
struct LumiOneApp: App {
    @StateObject private var model = LumiAppModel()

    var body: some Scene {
        WindowGroup("Lumi One") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 560)
        }
    }
}

@MainActor
final class LumiAppModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var status = "Starting…"
    @Published var lastError: String?
    @Published var isSafeMode = false
    @Published var isSending = false

    private var runtime: AgentRuntime?
    private let conversationID: UUID

    init() {
        let defaults = UserDefaults.standard
        if
            let storedID = defaults.string(forKey: "lumi.activeConversationID"),
            let parsedID = UUID(uuidString: storedID)
        {
            conversationID = parsedID
        } else {
            let newID = UUID()
            conversationID = newID
            defaults.set(newID.uuidString, forKey: "lumi.activeConversationID")
        }

        Task { await bootstrap() }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isSafeMode, let runtime else { return }

        draft = ""
        isSending = true
        lastError = nil
        status = "Thinking…"

        Task {
            defer { isSending = false }
            do {
                let response = try await runtime.send(text, conversationID: conversationID)
                messages = response.conversation.messages
                status = "Ready"
            } catch {
                lastError = String(describing: error)
                status = "Model error"

                // AgentRuntime persists the user message before model execution.
                // Reload so the UI never lies about what was successfully stored.
                if let restored = try? await runtime.loadConversation(id: conversationID) {
                    messages = restored.messages
                }
            }
        }
    }

    private func bootstrap() async {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            enterSafeMode("Application Support directory is unavailable.")
            return
        }

        let databaseURL = applicationSupport
            .appendingPathComponent("LumiOne", isDirectory: true)
            .appendingPathComponent("lumi.sqlite3")

        switch StorageBootstrap.openSQLite(at: databaseURL) {
        case .safeMode(let reason):
            enterSafeMode(reason)

        case .ready(let store):
            let environment = ProcessInfo.processInfo.environment
            let endpoint = environment["LUMI_MODEL_ENDPOINT"]
                .flatMap(URL.init(string:))
                ?? URL(string: "http://127.0.0.1:8080/v1/chat/completions")!
            let modelName = environment["LUMI_MODEL_NAME"] ?? "local"

            let provider = OpenAICompatibleProvider(
                endpoint: endpoint,
                model: modelName
            )
            let newRuntime = AgentRuntime(store: store, model: provider)
            runtime = newRuntime

            if let restored = try? await newRuntime.loadConversation(id: conversationID) {
                messages = restored.messages
            }

            status = "Ready"
        }
    }

    private func enterSafeMode(_ reason: String) {
        runtime = nil
        isSafeMode = true
        status = "SAFE MODE"
        lastError = "Persistent storage is unavailable. Writes are disabled. \(reason)"
    }
}

private struct ContentView: View {
    @EnvironmentObject private var model: LumiAppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            composer
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lumi One")
                    .font(.headline)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(model.isSafeMode ? .red : .secondary)
            }
            Spacer()
        }
        .padding()
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            List(model.messages) { message in
                VStack(alignment: .leading, spacing: 5) {
                    Text(label(for: message.role))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(message.content)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
                .id(message.id)
            }
            .overlay {
                if model.messages.isEmpty {
                    ContentUnavailableView(
                        "Lumi One",
                        systemImage: "sparkles",
                        description: Text("The runtime is online. Start a conversation.")
                    )
                }
            }
            .onChange(of: model.messages.count) { _, _ in
                if let last = model.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Lumi…", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .disabled(model.isSafeMode || model.isSending)
                    .onSubmit { model.send() }

                Button("Send") { model.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(
                        model.isSafeMode ||
                        model.isSending ||
                        model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding()
    }

    private func label(for role: ChatRole) -> String {
        switch role {
        case .system: return "System"
        case .user: return "You"
        case .assistant: return "Lumi"
        case .tool: return "Tool"
        }
    }
}

#else
import Foundation

@main
enum LumiMacUnsupportedPlatform {
    static func main() {
        print("LumiMac requires macOS with SwiftUI.")
    }
}
#endif
