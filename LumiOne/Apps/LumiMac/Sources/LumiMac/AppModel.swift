#if canImport(SwiftUI)
import AppKit
import Foundation
import SwiftUI
import LumiCore
import LumiMacSupport

@MainActor
final class LumiAppModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var status = "Starting…"
    @Published var lastError: String?
    @Published var pendingApproval: PendingToolApproval?
    @Published var selectedFiles: [UserFileDescriptor] = []
    @Published var knowledgeDocuments: [KnowledgeDocument] = []
    @Published var indexingResourceID: UserFileResourceID?
    @Published var isKnowledgeAvailable = false
    @Published var isSafeMode = false
    @Published var isSending = false

    private var runtime: AgentRuntime?
    private var store: SQLiteConversationStore?
    private var fileCatalog: SecurityScopedFileCatalog?
    private var knowledgeStore: SQLiteKnowledgeStore?
    private var knowledgeEngine: KnowledgeIngestionEngine?
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

    func selectFile() {
        guard
            !isSafeMode,
            !isSending,
            indexingResourceID == nil,
            pendingApproval == nil,
            let fileCatalog,
            let store
        else { return }

        let panel = NSOpenPanel()
        panel.title = "Select a file for Lumi"
        panel.prompt = "Select"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let descriptor = try fileCatalog.register(url: url)
            selectedFiles = fileCatalog.allDescriptors()
            try configureRuntime(store: store, broker: fileCatalog)
            status = "Ready"
            lastError = nil

            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = "Read the selected file \(descriptor.displayName)."
            }
        } catch {
            status = "File selection failed"
            lastError = String(describing: error)
        }
    }

    func ingestIntoKnowledge(_ descriptor: UserFileDescriptor) {
        guard
            !isSafeMode,
            !isSending,
            indexingResourceID == nil,
            pendingApproval == nil,
            let knowledgeEngine,
            let knowledgeStore
        else { return }

        indexingResourceID = descriptor.id
        status = "Indexing \(descriptor.displayName)…"
        lastError = nil

        Task {
            defer { indexingResourceID = nil }
            do {
                let result = try await knowledgeEngine.ingest(resourceID: descriptor.id)
                knowledgeDocuments = try await knowledgeStore.listDocuments()
                status = "Indexed \(result.document.displayName) — \(result.chunks.count) chunks"
            } catch {
                status = "Knowledge ingestion failed"
                lastError = String(describing: error)
            }
        }
    }

    func isIndexed(_ descriptor: UserFileDescriptor) -> Bool {
        knowledgeDocuments.contains { $0.sourceResourceID == descriptor.id }
    }

    func canIngest(_ descriptor: UserFileDescriptor) -> Bool {
        isKnowledgeAvailable && descriptor.displayName.lowercased().hasSuffix(".pdf")
    }

    func removeFile(_ descriptor: UserFileDescriptor) {
        guard
            !isSafeMode,
            !isSending,
            indexingResourceID == nil,
            pendingApproval == nil,
            let fileCatalog,
            let store
        else { return }

        do {
            try fileCatalog.remove(resourceID: descriptor.id)
            selectedFiles = fileCatalog.allDescriptors()
            try configureRuntime(store: store, broker: fileCatalog)
            status = "Ready"
            lastError = nil
        } catch {
            status = "File removal failed"
            lastError = String(describing: error)
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

        let root = applicationSupport.appendingPathComponent("LumiOne", isDirectory: true)
        let databaseURL = root.appendingPathComponent("lumi.sqlite3")

        switch StorageBootstrap.openSQLite(at: databaseURL) {
        case .safeMode(let reason):
            enterSafeMode(reason)

        case .ready(let openedStore):
            store = openedStore

            do {
                let openedKnowledgeStore = try SQLiteKnowledgeStore(
                    url: root.appendingPathComponent("knowledge.sqlite3")
                )
                knowledgeStore = openedKnowledgeStore
                knowledgeDocuments = try await openedKnowledgeStore.listDocuments()
            } catch {
                knowledgeStore = nil
                isKnowledgeAvailable = false
                lastError = "Knowledge storage is disabled: \(error)"
            }

            let broker: any UserFileAccessBroker
            do {
                let catalog = try SecurityScopedFileCatalog(
                    storeURL: root.appendingPathComponent("user-files.json")
                )
                fileCatalog = catalog
                selectedFiles = catalog.allDescriptors()
                broker = catalog

                if let knowledgeStore {
                    knowledgeEngine = KnowledgeIngestionEngine(
                        extractor: PDFKitDocumentExtractor(catalog: catalog),
                        store: knowledgeStore
                    )
                    isKnowledgeAvailable = true
                }
            } catch {
                // Conversation storage remains valid, so do not silently fall back
                // to unsafe direct paths. File access is disabled visibly instead.
                fileCatalog = nil
                selectedFiles = []
                broker = UnavailableUserFileAccessBroker()
                knowledgeEngine = nil
                isKnowledgeAvailable = false
                lastError = "User-file access is disabled: \(error)"
            }

            do {
                try configureRuntime(store: openedStore, broker: broker)

                if let restored = try? await runtime?.loadConversation(id: conversationID) {
                    messages = restored.messages
                }

                status = fileCatalog == nil ? "Ready — file access disabled" : "Ready"
            } catch {
                enterSafeMode("Runtime initialization failed: \(error)")
            }
        }
    }

    private func configureRuntime(
        store: SQLiteConversationStore,
        broker: any UserFileAccessBroker
    ) throws {
        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [
            AnyTool(ReadTextFileTool(broker: broker))
        ])
        let tools = ToolRuntime(registry: registry, permissions: permissions)

        let environment = ProcessInfo.processInfo.environment
        let endpoint = environment["LUMI_MODEL_ENDPOINT"]
            .flatMap(URL.init(string:))
            ?? URL(string: "http://127.0.0.1:8080/v1/chat/completions")!
        let modelName = environment["LUMI_MODEL_NAME"] ?? "local"

        let provider = OpenAICompatibleProvider(
            endpoint: endpoint,
            model: modelName,
            systemPrompt: makeSystemPrompt()
        )

        runtime = AgentRuntime(
            store: store,
            model: provider,
            toolRuntime: tools
        )
        pendingApproval = nil
    }

    private func makeSystemPrompt() -> String {
        var prompt = """
        You are Lumi, a precise local personal AI assistant.
        User-file access is capability-based. Never invent filesystem paths or resource IDs.
        Use file.readText only with a resourceID explicitly listed below.
        """

        if selectedFiles.isEmpty {
            prompt += "\nNo user-selected files are currently registered."
        } else {
            prompt += "\nUser-selected files currently registered with Lumi:"
            for descriptor in selectedFiles {
                // Deliberately omit the filesystem location from model context.
                prompt += "\n- \(descriptor.displayName) — resourceID: \(descriptor.id.rawValue)"
            }
        }

        return prompt
    }

    private func enterSafeMode(_ reason: String) {
        runtime = nil
        pendingApproval = nil
        knowledgeEngine = nil
        isKnowledgeAvailable = false
        isSafeMode = true
        status = "SAFE MODE"
        lastError = "Persistent runtime is unavailable. Writes and actions are disabled. \(reason)"
    }
}
#endif
