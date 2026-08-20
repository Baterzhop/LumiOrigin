#if canImport(SwiftUI)
import SwiftUI
import LumiCore

struct ContentView: View {
    @StateObject private var model = ChatViewModel()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            chatPanel
        }
        .frame(minWidth: 1040, minHeight: 720)
    }

    private var sidebar: some View {
        List {
            Section("Profile") {
                Picker("Profile", selection: $model.selectedProfile) {
                    ForEach(model.profiles, id: \.self) { profile in
                        Text(profile.capitalized).tag(profile)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Routing") {
                LabeledContent("Execution", value: model.classification.mode.rawValue)
                LabeledContent("Intent", value: model.lastIntent.rawValue)
                LabeledContent("Risk", value: model.classification.risk.rawValue)
                LabeledContent(
                    "Confidence",
                    value: model.classification.confidence.formatted(.percent.precision(.fractionLength(0)))
                )
                Text(model.classification.capabilities.map(\.rawValue).sorted().joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.classification.reasons.isEmpty {
                    Text(model.classification.reasons.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            AgentSidebarSection(model: model)

            Section("Runtime") {
                Label(model.status, systemImage: "circle.fill")
                LabeledContent("Messages", value: "\(model.messages.count)")

                if let runtime = model.runtime {
                    LabeledContent("Provider", value: runtime.provider.rawValue)
                    LabeledContent("Model", value: runtime.model)
                    if let latencyMs = runtime.latencyMs {
                        LabeledContent("Latency", value: "\(latencyMs) ms")
                    }
                }

                if let lastError = model.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section("Context budget") {
                if let budget = model.contextBudget {
                    LabeledContent("Input", value: "\(budget.estimatedInputTokens) / \(budget.inputBudgetTokens) tok")
                    LabeledContent("System", value: "\(budget.systemTokens) tok")
                    LabeledContent("History", value: "\(budget.historyTokens) tok")
                    LabeledContent("Memory", value: "\(budget.memoryTokens) tok")
                    LabeledContent("Knowledge", value: "\(budget.knowledgeTokens) tok")

                    if budget.droppedMessageCount > 0 {
                        LabeledContent("History dropped", value: "\(budget.droppedMessageCount)")
                    }
                    if budget.droppedMemoryCount > 0 {
                        LabeledContent("Memory dropped", value: "\(budget.droppedMemoryCount)")
                    }
                    if budget.droppedKnowledgeCount > 0 {
                        LabeledContent("Context dropped", value: "\(budget.droppedKnowledgeCount)")
                    }
                } else {
                    Text("No request packed yet")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Long-term memory") {
                TextField("Memory to keep…", text: $model.memoryDraft, axis: .vertical)
                    .lineLimit(1...3)

                HStack {
                    Button(model.editingMemoryID == nil ? "Remember" : "Save") {
                        model.saveMemoryDraft()
                    }
                    .disabled(model.memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if model.editingMemoryID != nil {
                        Button("Cancel") { model.cancelMemoryEdit() }
                    }
                }

                if model.storedMemories.isEmpty {
                    Text("No stored memories")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.storedMemories.prefix(6)) { memory in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(memory.kind.rawValue.capitalized)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                if memory.isPinned {
                                    Image(systemName: "pin.fill")
                                        .font(.caption)
                                }
                            }
                            Text(memory.content)
                                .font(.caption)
                                .lineLimit(3)
                                .textSelection(.enabled)
                            HStack {
                                Button {
                                    model.beginEditingMemory(memory)
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help("Edit memory")

                                Button(role: .destructive) {
                                    model.forgetMemory(memory)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Forget memory")
                            }
                        }
                    }
                }
            }

            if !model.relevantMemories.isEmpty {
                Section("Memory used this turn") {
                    ForEach(Array(model.relevantMemories.prefix(4).indices), id: \.self) { index in
                        let hit = model.relevantMemories[index]
                        VStack(alignment: .leading, spacing: 3) {
                            Text("[M\(index + 1)] \(hit.record.kind.rawValue.capitalized)")
                                .font(.subheadline.weight(.semibold))
                            Text(hit.record.content)
                                .font(.caption)
                                .lineLimit(2)
                            Text(hit.score.formatted(.number.precision(.fractionLength(3))))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Verified citations") {
                if model.citationReport.citations.isEmpty {
                    Text(model.citationReport.availableEvidenceCount > 0 ? "Retrieved evidence was not cited" : "No citations")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.citationReport.citations) { citation in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("[\(citation.marker)] \(citation.title)")
                                .font(.subheadline.weight(.semibold))
                            if let section = citation.section {
                                Text(section).font(.caption).foregroundStyle(.secondary)
                            }
                            if let page = citation.page {
                                Text("Page \(page)").font(.caption).foregroundStyle(.secondary)
                            }
                            if let sourceURI = citation.sourceURI {
                                Text(sourceURI)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if !model.citationReport.invalidMarkers.isEmpty {
                    Text("Invalid markers: \(model.citationReport.invalidMarkers.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Retrieved context") {
                if model.contextHits.isEmpty {
                    Text("No retrieved context")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.contextHits.prefix(4).indices), id: \.self) { index in
                        let hit = model.contextHits[index]
                        VStack(alignment: .leading, spacing: 3) {
                            Text("[S\(index + 1)] \(hit.document.title)")
                                .font(.subheadline.weight(.semibold))
                            Text(hit.score.formatted(.number.precision(.fractionLength(3))))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive, action: model.clear) {
                    Label("Clear conversation", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Lumi V4")
    }

    private var chatPanel: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lumi")
                    .font(.headline)
                Text("Local-first · capability-routed · bounded AgentRuntime · verified evidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isSending || model.isAgentRunning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if model.messages.isEmpty && model.streamingText.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                    if !model.streamingText.isEmpty {
                        StreamingMessageBubble(text: model.streamingText).id("streaming-response")
                    }
                }
                .padding(18)
            }
            .onChange(of: model.messages.count) { _ in scrollToBottom(proxy) }
            .onChange(of: model.streamingText) { _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if !model.streamingText.isEmpty {
            proxy.scrollTo("streaming-response", anchor: .bottom)
        } else if let id = model.messages.last?.id {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Lumi is ready")
                .font(.title3.weight(.semibold))
            Text("Chat remains non-agentic by default. Use Agent Runtime explicitly when you want Lumi to plan and invoke registered tools through its permission boundary.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 540)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 110)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Lumi…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .onSubmit(model.send)
                .disabled(model.isSending || model.isAgentRunning)

            if model.isSending {
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
                .disabled(
                    model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.isAgentRunning
                )
            }
        }
        .padding(14)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 90) }
            VStack(alignment: .leading, spacing: 5) {
                Text(message.role == .user ? "You" : "Lumi")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(message.content).textSelection(.enabled)
            }
            .padding(12)
            .background(
                message.role == .user ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 14)
            )
            if message.role != .user { Spacer(minLength: 90) }
        }
    }
}

private struct StreamingMessageBubble: View {
    let text: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Lumi")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ProgressView().controlSize(.mini)
                }
                Text(text).textSelection(.enabled)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            Spacer(minLength: 90)
        }
    }
}
#endif
