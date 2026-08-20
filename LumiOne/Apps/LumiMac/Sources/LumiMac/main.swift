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
    @Published var pendingApproval: PendingToolApproval?
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
        guard
            !text.isEmpty,
            !isSending,
            !isSafeMode,
            pendingApproval == nil,
            let runtime
        else { return }

        draft = ""
        isSending = true
        lastError = nil
        status = "Thinking…"

        Task {
            defer { isSending = false }
            do {
                let outcome = try await runtime.send(text, conversationID: conversationID)
                apply(outcome)
            } catch {
                await handleRuntimeError(error, runtime: runtime)
            }
        }
    }

    func approve(_ duration: GrantDuration) {
        guard let pendingApproval, let runtime, !isSending else { return }

        isSending = true
        lastError = nil
        status = "Running authorized action…"

        Task {
            defer { isSending = false }
            do {
                let outcome = try await runtime.approvePermission(
                    pendingID: pendingApproval.id,
                    duration: duration
                )
                apply(outcome)
            } catch {
                await handleRuntimeError(error, runtime: runtime)
            }
        }
    }

    func deny() {
        guard let pendingApproval, let runtime, !isSending else { return }

        isSending = true
        lastError = nil
        status = "Continuing without the action…"

        Task {
            defer { isSending = false }
            do {
                let outcome = try await runtime.denyPermission(pendingID: pendingApproval.id)
                apply(outcome)
            } catch {
                await handleRuntimeError(error, runtime: runtime)
            }
        }
    }

    private func apply(_ outcome: RuntimeOutcome) {
        switch outcome {
        case .completed(let response):
            pendingApproval = nil
            messages = response.conversation.messages
            status = "Ready"

        case .permissionRequired(let pending):
            pendingApproval = pending
            messages = pending.conversation.messages
            status = "Permission required"
        }
    }

    private func handleRuntimeError(_ error: Error, runtime: AgentRuntime) async {
        lastError = String(describing: error)
        status = "Runtime error"

        // The user message is persisted before model/tool execution. Reload so
        // the UI reflects durable state even when a later step fails.
        if let restored = try? await runtime.loadConversation(id: conversationID) {
            messages = restored.messages
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
            do {
                let permissions = PermissionEngine()
                let registry = try ToolRegistry(tools: [AnyTool(ReadTextFileTool())])
                let tools = ToolRuntime(registry: registry, permissions: permissions)

                let environment = ProcessInfo.processInfo.environment
                let endpoint = environment["LUMI_MODEL_ENDPOINT"]
                    .flatMap(URL.init(string:))
                    ?? URL(string: "http://127.0.0.1:8080/v1/chat/completions")!
                let modelName = environment["LUMI_MODEL_NAME"] ?? "local"

                let provider = OpenAICompatibleProvider(
                    endpoint: endpoint,
                    model: modelName
                )
                let newRuntime = AgentRuntime(
                    store: store,
                    model: provider,
                    toolRuntime: tools
                )
                runtime = newRuntime

                if let restored = try? await newRuntime.loadConversation(id: conversationID) {
                    messages = restored.messages
                }

                status = "Ready"
            } catch {
                enterSafeMode("Tool runtime initialization failed: \(error)")
            }
        }
    }

    private func enterSafeMode(_ reason: String) {
        runtime = nil
        pendingApproval = nil
        isSafeMode = true
        status = "SAFE MODE"
        lastError = "Persistent runtime is unavailable. Writes and actions are disabled. \(reason)"
    }
}

private struct ContentView: View {
    @EnvironmentObject private var model: LumiAppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            if let pending = model.pendingApproval {
                Divider()
                permissionPanel(pending)
            }
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

    private var visibleMessages: [ChatMessage] {
        model.messages.filter { $0.role == .user || $0.role == .assistant }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            List(visibleMessages) { message in
                VStack(alignment: .leading, spacing: 5) {
                    Text(message.role == .user ? "You" : "Lumi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(message.content)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
                .id(message.id)
            }
            .overlay {
                if visibleMessages.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.largeTitle)
                        Text("Lumi One")
                            .font(.title2)
                        Text("The runtime is online. Start a conversation.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onChange(of: visibleMessages.count) { _ in
                if let last = visibleMessages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func permissionPanel(_ pending: PendingToolApproval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lumi is requesting permission")
                .font(.headline)

            Text("Tool: \(pending.toolName)@\(pending.toolVersion)")
                .font(.subheadline)
            Text("Capability: \(pending.permission.capability.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(pending.permission.resource.identifier)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text(pending.permission.reason)
                .font(.caption)

            HStack {
                Button("Allow once") { model.approve(.once) }
                    .disabled(model.isSending)
                Button("Allow for session") { model.approve(.session) }
                    .disabled(model.isSending)
                Button("Deny", role: .cancel) { model.deny() }
                    .disabled(model.isSending)
                Spacer()
            }
        }
        .padding()
        .background(.quaternary.opacity(0.35))
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
                    .disabled(
                        model.isSafeMode ||
                        model.isSending ||
                        model.pendingApproval != nil
                    )
                    .onSubmit { model.send() }

                Button("Send") { model.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(
                        model.isSafeMode ||
                        model.isSending ||
                        model.pendingApproval != nil ||
                        model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding()
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
