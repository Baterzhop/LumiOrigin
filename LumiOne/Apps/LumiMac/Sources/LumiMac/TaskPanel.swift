#if canImport(SwiftUI)
import SwiftUI
import LumiCore

struct TaskPanel: View {
    @EnvironmentObject private var model: LumiAppModel
    @State private var newTitle = ""
    @State private var newInstruction = ""
    @State private var newMaxAttempts = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Tasks", systemImage: "checklist")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("durable · local · explicit execution")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.tasks.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            createRow

            if model.tasks.isEmpty {
                Text("No durable tasks. Create one here or explicitly ask Lumi to create one and approve the task mutation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(model.tasks) { record in
                            TaskEditorCard(
                                record: record,
                                selected: model.selectedTaskID == record.id,
                                disabled: model.isSending || model.pendingApproval != nil,
                                taskPermissionOwner: model.pendingTaskApprovalID,
                                onSelect: { model.selectTask(record) },
                                onSave: { title, instruction, attempts in
                                    model.updateTask(
                                        record,
                                        title: title,
                                        instruction: instruction,
                                        maxAttempts: attempts
                                    )
                                },
                                onReady: { model.markTaskReady(record) },
                                onStart: { model.startTask(record) },
                                onResume: { model.resumeTask(record) },
                                onCancel: { model.cancelTask(record) }
                            )
                            .id("\(record.id.description)-\(record.revision)")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }

            if model.selectedTaskID != nil, !model.selectedTaskEvents.isEmpty {
                auditTrail
            }
        }
        .padding(.top, 8)
    }

    private var createRow: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField("Task title", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 150, idealWidth: 190, maxWidth: 220)

            TextField("What should Lumi do?", text: $newInstruction, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .frame(minWidth: 240)

            Stepper(
                "Attempts: \(newMaxAttempts)",
                value: $newMaxAttempts,
                in: 1...TaskValidation.maximumAttempts
            )
            .font(.caption)
            .frame(width: 120)

            Button("Create") {
                model.createTask(
                    title: newTitle,
                    instruction: newInstruction,
                    maxAttempts: newMaxAttempts
                )
                newTitle = ""
                newInstruction = ""
                newMaxAttempts = 3
            }
            .disabled(
                model.isSafeMode ||
                model.isSending ||
                model.pendingApproval != nil ||
                newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                newInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(.horizontal)
    }

    private var auditTrail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Selected task audit")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.selectedTaskEvents) { event in
                        HStack(spacing: 5) {
                            Text("r\(event.revision)")
                                .font(.caption2.monospaced())
                                .fontWeight(.semibold)
                            Text(event.toState.rawValue)
                            Text("· \(event.actor.rawValue)")
                                .foregroundStyle(.secondary)
                            if let reason = event.reason, !reason.isEmpty {
                                Text("· \(reason)")
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.35), in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

private struct TaskEditorCard: View {
    let record: TaskRecord
    let selected: Bool
    let disabled: Bool
    let taskPermissionOwner: TaskID?
    let onSelect: () -> Void
    let onSave: (String, String, Int) -> Void
    let onReady: () -> Void
    let onStart: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var instruction: String
    @State private var maxAttempts: Int

    init(
        record: TaskRecord,
        selected: Bool,
        disabled: Bool,
        taskPermissionOwner: TaskID?,
        onSelect: @escaping () -> Void,
        onSave: @escaping (String, String, Int) -> Void,
        onReady: @escaping () -> Void,
        onStart: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.record = record
        self.selected = selected
        self.disabled = disabled
        self.taskPermissionOwner = taskPermissionOwner
        self.onSelect = onSelect
        self.onSave = onSave
        self.onReady = onReady
        self.onStart = onStart
        self.onResume = onResume
        self.onCancel = onCancel
        _title = State(initialValue: record.title)
        _instruction = State(initialValue: record.instruction)
        _maxAttempts = State(initialValue: record.maxAttempts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button(action: onSelect) {
                    Label(record.state.rawValue, systemImage: stateIcon)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.plain)

                Spacer()
                Text("r\(record.revision)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .disabled(!record.state.isEditable || disabled)

            TextField("Instruction", text: $instruction, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .disabled(!record.state.isEditable || disabled)

            HStack {
                Text("Attempts \(record.attemptCount)/\(record.maxAttempts)")
                if let next = record.nextEligibleAt {
                    Text("· eligible \(next.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if record.state.isEditable {
                Stepper(
                    "Max: \(maxAttempts)",
                    value: $maxAttempts,
                    in: max(1, record.attemptCount)...TaskValidation.maximumAttempts
                )
                .font(.caption2)
                .disabled(disabled)
            }

            if let error = record.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .help(error)
            }

            if let result = record.resultSummary, !result.isEmpty {
                Text(result)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(result)
            }

            HStack(spacing: 6) {
                if record.state.isEditable {
                    Button("Save") {
                        onSave(title, instruction, maxAttempts)
                    }
                    .disabled(disabled || !hasEditChanges || invalidEdit)
                }

                if record.state == .draft {
                    Button("Ready", action: onReady)
                        .disabled(disabled)
                }

                if record.state == .ready {
                    Button("Start", action: onStart)
                        .disabled(disabled)
                }

                if record.state == .failed || record.state == .interrupted {
                    Button("Resume", action: onResume)
                        .disabled(disabled || record.attemptCount >= record.maxAttempts)
                }

                if record.state != .succeeded && record.state != .cancelled {
                    Button("Cancel", role: .destructive, action: onCancel)
                        .disabled(cancelDisabled)
                }
            }
            .font(.caption)
        }
        .padding(9)
        .frame(width: 330, alignment: .leading)
        .background(
            selected ? .quaternary.opacity(0.65) : .quaternary.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var hasEditChanges: Bool {
        title != record.title ||
        instruction != record.instruction ||
        maxAttempts != record.maxAttempts
    }

    private var invalidEdit: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var cancelDisabled: Bool {
        if let taskPermissionOwner {
            return taskPermissionOwner != record.id
        }
        return disabled
    }

    private var stateIcon: String {
        switch record.state {
        case .draft: return "square.and.pencil"
        case .ready: return "play.circle"
        case .running: return "bolt.circle"
        case .waitingForPermission: return "lock.circle"
        case .interrupted: return "pause.circle"
        case .succeeded: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        }
    }
}
#endif
