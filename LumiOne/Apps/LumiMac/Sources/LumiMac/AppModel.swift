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
    @Published var pendingMemoryExisting: UserMemoryRecord?
    @Published var selectedFiles: [UserFileDescriptor] = []
    @Published var knowledgeDocuments: [KnowledgeDocument] = []
    @Published var memories: [UserMemoryRecord] = []
    @Published var lastCitations: [KnowledgeCitation] = []
    @Published var indexingResourceID: UserFileResourceID?
    @Published var isKnowledgeAvailable = false
    @Published var isMemoryAvailable = false
    @Published var isSafeMode = false
    @Published var isSending = false

    private var runtime: AgentRuntime?
    private var store: SQLiteConversationStore?
    private var fileCatalog: SecurityScopedFileCatalog?
    private var knowledgeStore: SQLiteKnowledgeStore?
    private var knowledgeEngine: KnowledgeIngestionEngine?
    private var memoryStore: SQLiteMemoryStore?
    private var memoryService: MemoryService?
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
        lastCitations = []
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

    /// Explicit UI edit initiated by the user. This does not route through the
    /// model permission flow because the user is directly editing the memory.
    /// Optimistic revision matching still prevents stale UI from overwriting a
    /// newer value.
    func updateMemory(_ record: UserMemoryRecord, value: String) {
        guard
            !isSafeMode,
            !isSending,
            pendingApproval == nil,
            let memoryService
        else { return }

        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        isSending = true
        lastError = nil
        status = "Updating memory…"
        Task {
            defer { isSending = false }
            do {
                _ = try await memoryService.remember(
                    key: record.key,
                    kind: record.kind,
                    value: normalized,
                    confidence: record.confidence,
                    provenance: MemoryProvenance(
                        sourceKind: .manualUserEntry,
                        note: "Edited directly in Lumi Memory UI"
                    ),
                    expectedRevision: record.revision
                )
                await refreshMemories()
                status = "Memory updated"
            } catch {
                status = "Memory update failed"
                lastError = String(describing: error)
                await refreshMemories()
            }
        }
    }

    /// Explicit user-initiated hard forget. SQLiteMemoryStore cascades removal of
    /// revision payloads so deleted personal content is not retained secretly.
    func forgetMemory(_ record: UserMemoryRecord) {
        guard
            !isSafeMode,
            !isSending,
            pendingApproval == nil,
            let memoryService
        else { return }

        isSending = true
        lastError = nil
        status = "Forgetting memory…"
        Task {
            defer { isSending = false }
            do {
                _ = try await memoryService.forget(
                    key: record.key,
                    expectedRevision: record.revision
                )
                await refreshMemories()
                status = "Memory forgotten"
            } catch {
                status = "Memory deletion failed"
                lastError = String(describing: error)
                await refreshMemories()
            }
        }
    }

    private func apply(_ outcome: RuntimeOutcome) {
        switch outcome {
        case .completed(let response):
            pendingApproval = nil
            pendingMemoryExisting = nil
            messages = response.conversation.messages
            lastCitations = response.citations
            status = "Ready"
            if isMemoryAvailable {
                Task { await refreshMemories() }
            }

        case .permissionRequired(let pending):
            pendingApproval = pending
            pendingMemoryExisting = nil
            messages = pending.conversation.messages
            status = "Permission required"
            loadPendingMemoryState(for: pending)
        }
    }

    private func loadPendingMemoryState(for pending: PendingToolApproval) {
        guard
            pending.permission.resource.kind == .userMemory,
            let memoryService
        else { return }

        let pendingID = pending.id
        let key = pending.permission.resource.identifier
        Task {
            let existing = try? await memoryService.load(key: key)
            guard pendingApproval?.id == pendingID else { return }
            pendingMemoryExisting = existing
        }
    }

    private func handleRuntimeError(_ error: Error, runtime: AgentRuntime) async {
        lastError = String(describing: error)
        lastCitations = []
        pendingMemoryExisting = nil
        status = "Runtime error"

        if let restored = try? await runtime.loadConversation(id: conversationID) {
            messages = restored.messages
        }
        if isMemoryAvailable {
            await refreshMemories()
        }
    }

    private func refreshMemories() async {
        guard let memoryService else {
            memories = []
            return
        }
        do {
            memories = try await memoryService.listActive()
        } catch {
            lastError = "Memory refresh failed: \(error)"
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

            do {
                let openedMemoryStore = try SQLiteMemoryStore(
                    url: root.appendingPathComponent("memory.sqlite3")
                )
                memoryStore = openedMemoryStore
                let openedMemoryService = MemoryService(store: openedMemoryStore)
                memoryService = openedMemoryService
                memories = try await openedMemoryService.listActive()
                isMemoryAvailable = true
            } catch {
                memoryStore = nil
                memoryService = nil
                memories = []
                isMemoryAvailable = false
                lastError = "Long-term memory is disabled: \(error)"
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
        var registeredTools: [AnyTool] = [
            AnyTool(ReadTextFileTool(broker: broker))
        ]
        if let memoryService {
            registeredTools.append(AnyTool(RememberMemoryTool(service: memoryService)))
            registeredTools.append(AnyTool(ForgetMemoryTool(service: memoryService)))
        }
        let registry = try ToolRegistry(tools: registeredTools)
        let tools = ToolRuntime(registry: registry, permissions: permissions)

        var knowledgeContextProvider: (any ModelContextProvider)?
        if let knowledgeStore {
            knowledgeContextProvider = KnowledgeModelContextProvider(
                retriever: LexicalKnowledgeRetriever(store: knowledgeStore)
            )
        }

        var memoryContextProvider: (any ModelContextProvider)?
        if let memoryStore {
            memoryContextProvider = MemoryModelContextProvider(
                retriever: LexicalMemoryRetriever(store: memoryStore)
            )
        }

        let contextProvider: (any ModelContextProvider)?
        if knowledgeContextProvider != nil || memoryContextProvider != nil {
            contextProvider = CompositeModelContextProvider(
                knowledgeProvider: knowledgeContextProvider,
                memoryProvider: memoryContextProvider
            )
        } else {
            contextProvider = nil
        }

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
            toolRuntime: tools,
            contextProvider: contextProvider
        )
        pendingApproval = nil
        pendingMemoryExisting = nil
    }

    private func makeSystemPrompt() -> String {
        var prompt = """
        You are Lumi, a precise local personal AI assistant.
        User-file access is capability-based. Never invent filesystem paths or resource IDs.
        Use file.readText only with a resourceID explicitly listed below.
        Persistent user memory is explicit and user-controlled. Use memory.remember or memory.forget only when the user clearly asks to persist, replace, or forget information. Never claim a memory changed unless the corresponding tool succeeds. Do not automatically extract or store every chat detail.
        """

        if selectedFiles.isEmpty {
            prompt += "\nNo user-selected files are currently registered."
        } else {
            prompt += "\nUser-selected files currently registered with Lumi:"
            for descriptor in selectedFiles {
                prompt += "\n- \(descriptor.displayName) — resourceID: \(descriptor.id.rawValue)"
            }
        }

        return prompt
    }

    private func enterSafeMode(_ reason: String) {
        runtime = nil
        pendingApproval = nil
        pendingMemoryExisting = nil
        knowledgeEngine = nil
        memoryStore = nil
        memoryService = nil
        memories = []
        lastCitations = []
        isKnowledgeAvailable = false
        isMemoryAvailable = false
        isSafeMode = true
        status = "SAFE MODE"
        lastError = "Persistent runtime is unavailable. Writes and actions are disabled. \(reason)"
    }
}
#endif
