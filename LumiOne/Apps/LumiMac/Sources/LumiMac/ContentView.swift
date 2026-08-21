#if canImport(SwiftUI)
import SwiftUI
import LumiCore

struct ContentView: View {
    @EnvironmentObject private var model: LumiAppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.selectedFiles.isEmpty {
                Divider()
                selectedFileBar
            }
            if model.inspectedTable != nil {
                Divider()
                tablePanel
            }
            if model.isMemoryAvailable {
                Divider()
                memoryPanel
            }
            Divider()
            conversation
            if !model.lastCitations.isEmpty {
                Divider()
                citationBar
            }
            if let pending = model.pendingApproval {
                Divider()
                permissionPanel(pending)
            }
            Divider()
            composer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lumi One")
                    .font(.headline)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(model.isSafeMode ? .red : .secondary)
            }

            if !model.knowledgeDocuments.isEmpty {
                Text("Knowledge: \(model.knowledgeDocuments.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.isMemoryAvailable {
                Text("Memory: \(model.memories.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.selectSpreadsheetOutput()
            } label: {
                Label("New Table Output…", systemImage: "tablecells.badge.ellipsis")
            }
            .disabled(
                model.isSafeMode ||
                model.isSending ||
                model.indexingResourceID != nil ||
                model.inspectingResourceID != nil ||
                model.pendingApproval != nil
            )

            Button {
                model.selectFile()
            } label: {
                Label("Select File…", systemImage: "doc.badge.plus")
            }
            .disabled(
                model.isSafeMode ||
                model.isSending ||
                model.indexingResourceID != nil ||
                model.inspectingResourceID != nil ||
                model.pendingApproval != nil
            )
        }
        .padding()
    }

    private var selectedFileBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(model.selectedFiles, id: \.id) { descriptor in
                    HStack(spacing: 6) {
                        Image(systemName: model.canInspectSpreadsheet(descriptor) ? "tablecells" : "doc.text")
                        Text(descriptor.displayName)
                            .lineLimit(1)

                        if model.isSpreadsheetOutput(descriptor) {
                            Text("OUTPUT")
                                .font(.caption2.monospaced())
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                        }

                        if model.inspectingResourceID == descriptor.id {
                            ProgressView()
                                .controlSize(.small)
                                .help("Inspecting this table")
                        } else if model.canInspectSpreadsheet(descriptor) && !model.isSpreadsheetOutput(descriptor) {
                            Button("Inspect") {
                                model.inspectSpreadsheet(descriptor)
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.isSending || model.pendingApproval != nil)
                        }

                        if model.indexingResourceID == descriptor.id {
                            ProgressView()
                                .controlSize(.small)
                                .help("Adding this PDF to Knowledge")
                        } else if model.isIndexed(descriptor) {
                            Label("Indexed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        } else if model.canIngest(descriptor) {
                            Button("Add to Knowledge") {
                                model.ingestIntoKnowledge(descriptor)
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.isSending || model.pendingApproval != nil)
                        }

                        Button {
                            model.removeFile(descriptor)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this file from Lumi")
                        .disabled(model.indexingResourceID != nil || model.inspectingResourceID != nil)
                    }
                    .font(.caption)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.45), in: Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var tablePanel: some View {
        Group {
            if let table = model.inspectedTable {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("Table Preview", systemImage: "tablecells")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("\(table.displayName) · \(table.rowCount) rows × \(table.columnCount) columns")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if table.previewTruncated {
                            Text("bounded preview")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)

                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(table.columns.map(\.name).joined(separator: "  │  "))
                                .font(.caption.monospaced())
                                .fontWeight(.semibold)
                            ForEach(table.preview, id: \.rowIndex) { row in
                                Text(row.values.joined(separator: "  │  "))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var memoryPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Long-term Memory", systemImage: "tray.full")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("User-controlled · local")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)

            if model.memories.isEmpty {
                Text("No persistent memories. Lumi only stores one when you explicitly approve a memory operation or edit Memory directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 7)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(model.memories) { record in
                            MemoryEditorCard(
                                record: record,
                                disabled: model.isSending || model.pendingApproval != nil,
                                onSave: { value in
                                    model.updateMemory(record, value: value)
                                },
                                onForget: {
                                    model.forgetMemory(record)
                                }
                            )
                            .id(record.currentRevision.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(.top, 8)
    }

    private var citationBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Label("Sources", systemImage: "books.vertical")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(model.lastCitations, id: \.label) { citation in
                    HStack(spacing: 5) {
                        Text("[\(citation.label)]")
                            .fontWeight(.semibold)
                        Text(citation.displayName)
                            .lineLimit(1)
                        Text(pageLabel(citation))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.45), in: Capsule())
                    .help("Chunk \(citation.chunkOrdinal + 1) · source \(citation.sourceResourceID.rawValue)")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func pageLabel(_ citation: KnowledgeCitation) -> String {
        if citation.pageStart == citation.pageEnd {
            return "p. \(citation.pageStart)"
        }
        return "pp. \(citation.pageStart)–\(citation.pageEnd)"
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
                        Text("The runtime is online. Start a conversation or select a file.")
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

            if let displayName = pending.permission.resourceDisplayName {
                Label(
                    displayName,
                    systemImage: pending.permission.resource.kind == .userMemory
                        ? "tray.full"
                        : "doc"
                )
                .font(.subheadline)
            }

            if let location = pending.permission.resourceLocationHint {
                Text(location)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if pending.permission.resource.kind == .userMemory {
                memoryPermissionDetails(pending)
            }
            if pending.permission.details["operation"] == "spreadsheet.writeMutation" {
                spreadsheetPermissionDetails(pending)
            }

            Text("Capability: \(pending.permission.capability.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Authorization scope: \(pending.permission.resource.kind.rawValue) / \(pending.permission.resource.identifier)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text(pending.permission.reason)
                .font(.caption)

            HStack {
                Button("Allow once") { model.approve(.once) }
                    .disabled(model.isSending)
                if pending.permission.capability.supportsSessionGrant {
                    Button("Allow for session") { model.approve(.session) }
                        .disabled(model.isSending)
                }
                Button("Deny", role: .cancel) { model.deny() }
                    .disabled(model.isSending)
                Spacer()
            }
        }
        .padding()
        .background(.quaternary.opacity(0.35))
    }

    @ViewBuilder
    private func memoryPermissionDetails(_ pending: PendingToolApproval) -> some View {
        let details = pending.permission.details

        VStack(alignment: .leading, spacing: 5) {
            if let existing = model.pendingMemoryExisting {
                Text("Current value")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(existing.value)
                    .font(.caption)
                    .textSelection(.enabled)
                Text("Current revision: \(existing.revision)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("Current value: none")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let proposedValue = details["proposedValue"] {
                Text("Proposed value")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(proposedValue)
                    .font(.caption)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                if let kind = details["kind"] {
                    Text("Kind: \(kind)")
                }
                if let confidence = details["confidence"] {
                    Text("Confidence: \(confidence)")
                }
                if let revision = details["expectedRevision"] {
                    Text("Expected rev: \(revision)")
                }
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)

            if details["operation"] == "forget" {
                Text("This permanently removes the active memory and its stored revision payloads.")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func spreadsheetPermissionDetails(_ pending: PendingToolApproval) -> some View {
        let details = pending.permission.details

        VStack(alignment: .leading, spacing: 5) {
            Text("Previewed spreadsheet write")
                .font(.caption)
                .fontWeight(.semibold)

            if let rows = details["rows"], let columns = details["columns"] {
                Text("Output size: \(rows) rows × \(columns) columns")
                    .font(.caption)
            }
            if let names = details["columnNames"] {
                Text("Columns: \(names)")
                    .font(.caption)
                    .textSelection(.enabled)
            }
            if let source = details["sourceResourceID"] {
                Text("Source resource: \(source)")
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
            if let output = details["outputResourceID"] {
                Text("Output resource: \(output)")
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
            if let overwrite = details["overwritePolicy"] {
                Text("Overwrite policy: \(overwrite)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let defense = details["formulaInjectionDefense"] {
                Text("Formula-injection defense: \(defense)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text("The write is bound to this exact ephemeral preview plan and is approved once only.")
                .font(.caption)
                .fontWeight(.semibold)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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

private struct MemoryEditorCard: View {
    let record: UserMemoryRecord
    let disabled: Bool
    let onSave: (String) -> Void
    let onForget: () -> Void

    @State private var value: String

    init(
        record: UserMemoryRecord,
        disabled: Bool,
        onSave: @escaping (String) -> Void,
        onForget: @escaping () -> Void
    ) {
        self.record = record
        self.disabled = disabled
        self.onSave = onSave
        self.onForget = onForget
        _value = State(initialValue: record.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.key)
                .font(.caption.monospaced())
                .fontWeight(.semibold)
                .lineLimit(1)

            Text("\(record.kind.rawValue) · rev \(record.revision) · confidence \(record.confidence)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextField("Memory value", text: $value, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(disabled)

            HStack {
                Button("Save") {
                    onSave(value)
                }
                .disabled(
                    disabled ||
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    value == record.value
                )

                Button("Forget", role: .destructive) {
                    onForget()
                }
                .disabled(disabled)

                Spacer()
            }
        }
        .padding(10)
        .frame(width: 300, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
#endif