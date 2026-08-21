import SwiftUI
import UniformTypeIdentifiers
import LumiClientCore

struct ContentView: View {
    @StateObject private var model = ChatViewModel()
    @State private var showImporter = false
    @State private var showMemoryManager = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            chat
        }
        .frame(minWidth: 1100, minHeight: 720)
        .task { await model.refreshRuntime() }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importKnowledge(url)
            }
        }
        .sheet(isPresented: $showMemoryManager) {
            MemoryManagerView(model: model)
                .frame(minWidth: 680, minHeight: 560)
        }
    }

    private var sidebar: some View {
        List {
            Section("Runtime") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.status.contains("offline") || model.status.contains("error") ? Color.red : Color.green)
                        .frame(width: 8, height: 8)
                    Text(model.status)
                }
                LabeledContent("Core", value: model.coreVersion)
                LabeledContent("Provider", value: model.providerName)
                LabeledContent("Model", value: model.modelName)
            }

            Section("Knowledge · M2") {
                Label("\(model.documentCount) documents", systemImage: "books.vertical")
                Text(model.knowledgeStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    showImporter = true
                } label: {
                    Label(model.isImportingKnowledge ? "Importing…" : "Import document", systemImage: "doc.badge.plus")
                }
                .disabled(model.isImportingKnowledge)
                Button("Refresh index") {
                    Task { await model.refreshKnowledge() }
                }
            }

            Section("Memory · M4") {
                Label("\(model.memories.count) durable memories", systemImage: "brain")
                Text(model.memorySemanticEnabled ? "Semantic + lexical recall" : "Lexical recall")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(model.memoryStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    showMemoryManager = true
                } label: {
                    Label("Manage memory", systemImage: "slider.horizontal.3")
                }
                Button("Refresh memory") {
                    Task { await model.refreshMemories() }
                }
            }

            Section("Agent tools · M3") {
                Label("\(model.toolCount) registered tools", systemImage: "wrench.and.screwdriver")
                Text(model.toolWorkspace)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                TextField("Agent goal…", text: $model.agentGoal, axis: .vertical)
                    .lineLimit(1...4)
                Button {
                    model.runAgentTask()
                } label: {
                    Label(model.isRunningAgent ? "Working…" : "Run bounded task", systemImage: "play.circle")
                }
                .disabled(model.agentGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRunningAgent)

                Text(model.agentStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let task = model.agentTask {
                    LabeledContent("State", value: task.status)
                    LabeledContent("Steps", value: "\(task.stepCount)/\(task.maxSteps)")
                }

                if let call = model.pendingToolCall {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Approval required")
                            .font(.caption.weight(.semibold))
                        Text(call.toolName)
                            .font(.caption.monospaced())
                        Text("Risk: \(call.risk)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let arguments = call.argumentsPreview {
                            Text("Arguments")
                                .font(.caption2.weight(.semibold))
                            Text(arguments)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(8)
                        }
                        if let reason = call.decisionReason {
                            Text(reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Deny", role: .destructive) {
                                model.denyPendingTool()
                            }
                            Button("Approve") {
                                model.approvePendingTool()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Section("Conversation") {
                Text(model.conversationID ?? "New conversation")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button("New conversation", action: model.newConversation)
                    .disabled(model.isGenerating)
            }

            Section("Capabilities") {
                Label("SSE streaming", systemImage: "waveform")
                Label("Hybrid RAG + citations", systemImage: "text.magnifyingglass")
                Label("Approved durable memory", systemImage: "brain")
                Label("Sandboxed tools + approval", systemImage: "lock.shield")
                Label("Durable audit log", systemImage: "list.bullet.rectangle")
            }
        }
        .navigationTitle("Lumi V4")
    }

    private var chat: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lumi").font(.headline)
                Text("Local-first AI runtime · grounded knowledge · durable memory · policy-gated tools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isGenerating || model.isRunningAgent { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if model.messages.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 44))
                                .foregroundStyle(.secondary)
                            Text("Lumi is ready").font(.title3.weight(.semibold))
                            Text("Chat uses grounded local knowledge and only recalls durable memories that you explicitly saved. Agent side effects remain approval-gated.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 620)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 110)
                    }
                    ForEach(model.messages) { message in
                        MessageBubbleView(message: message).id(message.id)
                    }
                }
                .padding(18)
            }
            .onChange(of: model.messages.last?.content) { _ in
                if let id = model.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Lumi…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .onSubmit { if !model.isGenerating { model.send() } }

            if model.isGenerating {
                Button(action: model.stop) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .help("Stop generation")
            } else {
                Button(action: model.send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
            }
        }
        .padding(14)
    }
}

private struct MessageBubbleView: View {
    let message: ChatBubble

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 100) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(message.role == .user ? "You" : "Lumi")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let model = message.model, message.role == .assistant {
                        Text(model).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }

                if message.content.isEmpty && message.role == .assistant {
                    Text("…").foregroundStyle(.secondary)
                } else {
                    Text(message.content).textSelection(.enabled)
                }

                if message.role == .assistant && !message.memories.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text("Recalled memory")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(message.memories.prefix(4).enumerated()), id: \.element.id) { index, memory in
                        HStack(alignment: .top, spacing: 6) {
                            Text("M\(index + 1)")
                                .font(.caption2.monospaced().weight(.bold))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(memory.title ?? memory.kind.capitalized)
                                    .font(.caption)
                                Text(memory.content)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(memory.retrieval.joined(separator: "+"))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                if message.role == .assistant && !message.citations.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text("Sources").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(message.citations.prefix(6).enumerated()), id: \.element.id) { index, source in
                        HStack(alignment: .top, spacing: 6) {
                            Text("S\(index + 1)")
                                .font(.caption2.monospaced().weight(.bold))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title ?? source.source ?? source.documentID)
                                    .font(.caption)
                                HStack(spacing: 8) {
                                    if let page = source.page { Text("page \(page)") }
                                    Text(source.retrieval.joined(separator: "+"))
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(
                message.role == .user ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 14)
            )
            if message.role == .assistant { Spacer(minLength: 100) }
        }
    }
}

private struct MemoryManagerView: View {
    @ObservedObject var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var newTitle = ""
    @State private var newContent = ""
    @State private var newKind = "fact"
    @State private var editingMemory: MemoryRecordDTO?

    private let kinds = ["fact", "preference", "project", "note"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lumi Memory").font(.title2.weight(.semibold))
                    Text("Only items you explicitly save here become durable memory. You can edit or permanently delete them at any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            List(model.memories) { memory in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(memory.title ?? memory.kind.capitalized)
                            .font(.headline)
                        Spacer()
                        Text(memory.kind)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(memory.content)
                        .textSelection(.enabled)
                        .lineLimit(4)
                    HStack {
                        Button("Edit") { editingMemory = memory }
                        Button("Delete", role: .destructive) { model.deleteMemory(memory.id) }
                        Spacer()
                        Text(memory.updatedAt)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if model.memories.isEmpty {
                    Text("No approved durable memories yet.")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            Text("Save a memory").font(.headline)
            HStack {
                TextField("Optional title", text: $newTitle)
                Picker("Kind", selection: $newKind) {
                    ForEach(kinds, id: \.self) { kind in Text(kind.capitalized).tag(kind) }
                }
                .frame(width: 150)
            }
            TextEditor(text: $newContent)
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Text("Saving is an explicit approval for Lumi to recall this item in future chats.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Remember") {
                    model.createMemory(
                        content: newContent,
                        title: newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newTitle,
                        kind: newKind
                    )
                    newTitle = ""
                    newContent = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isUpdatingMemory)
            }
        }
        .padding(18)
        .task { await model.refreshMemories() }
        .sheet(item: $editingMemory) { memory in
            MemoryEditView(memory: memory) { content, title, kind in
                model.updateMemory(memory, content: content, title: title, kind: kind)
                editingMemory = nil
            }
            .frame(minWidth: 520, minHeight: 360)
        }
    }
}

private struct MemoryEditView: View {
    let memory: MemoryRecordDTO
    let onSave: (String, String?, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var content: String
    @State private var kind: String

    private let kinds = ["fact", "preference", "project", "note"]

    init(memory: MemoryRecordDTO, onSave: @escaping (String, String?, String) -> Void) {
        self.memory = memory
        self.onSave = onSave
        _title = State(initialValue: memory.title ?? "")
        _content = State(initialValue: memory.content)
        _kind = State(initialValue: memory.kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit memory").font(.title3.weight(.semibold))
            TextField("Title", text: $title)
            Picker("Kind", selection: $kind) {
                ForEach(kinds, id: \.self) { value in Text(value.capitalized).tag(value) }
            }
            TextEditor(text: $content)
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(content, cleanTitle.isEmpty ? nil : cleanTitle, kind)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
    }
}
