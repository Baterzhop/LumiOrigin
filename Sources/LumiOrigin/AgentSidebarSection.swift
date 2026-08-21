#if canImport(SwiftUI)
import SwiftUI
import LumiCore

struct AgentSidebarSection: View {
    @ObservedObject var model: ChatViewModel

    var body: some View {
        Group {
            Section("Agent Runtime") {
                TextField("Goal for Agent…", text: $model.agentGoal, axis: .vertical)
                    .lineLimit(2...5)

                HStack {
                    Button {
                        model.startAgent()
                    } label: {
                        Label("Run Agent", systemImage: "play.circle")
                    }
                    .disabled(
                        model.agentGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isAgentRunning
                        || model.isSending
                    )

                    if model.isAgentRunning {
                        ProgressView().controlSize(.small)
                        Button("Stop") { model.cancelActiveAgent() }
                    }
                }

                if let activity = model.agentActivity, !activity.isEmpty {
                    Label(activity, systemImage: "waveform.path")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let run = model.activeAgentRun {
                    runSummary(run)
                }

                if !model.recentAgentRuns.isEmpty {
                    DisclosureGroup("Recent runs") {
                        ForEach(model.recentAgentRuns.prefix(5)) { run in
                            Button {
                                model.selectAgentRun(run)
                            } label: {
                                HStack {
                                    Text(run.goal)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(run.state.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .font(.caption)
                }
            }

            KnowledgeSidebarSection()
        }
    }

    @ViewBuilder
    private func runSummary(_ run: AgentRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(run.state.rawValue)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(run.steps.count)/\(run.budget.maxSteps) steps")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(run.goal)
                .font(.caption)
                .lineLimit(3)
                .textSelection(.enabled)

            if let classification = run.classification {
                Text("\(classification.mode.rawValue) · risk \(classification.risk.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(run.steps.suffix(4)) { step in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Step \(step.index) · \(step.call.toolName)")
                        .font(.caption.weight(.semibold))
                    Text(step.result.status.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let error = step.result.error, !error.isEmpty {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    }
                }
            }

            if run.state == .waitingForConfirmation, let call = run.pendingCall {
                confirmationPanel(call)
            }

            if let finalAnswer = run.finalAnswer, !finalAnswer.isEmpty {
                Divider()
                Text("Result")
                    .font(.caption.weight(.semibold))
                Text(finalAnswer)
                    .font(.caption)
                    .textSelection(.enabled)
            }

            if let error = model.agentError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func confirmationPanel(_ call: ToolCall) -> some View {
        Divider()
        Label("Approval required", systemImage: "hand.raised.fill")
            .font(.caption.weight(.semibold))

        Text(call.toolName)
            .font(.caption.monospaced())
            .textSelection(.enabled)

        if call.arguments.isEmpty {
            Text("No arguments")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            ForEach(call.arguments.keys.sorted(), id: \.self) { key in
                if let value = call.arguments[key] {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key)
                            .font(.caption2.weight(.semibold))
                        Text(renderToolValue(value))
                            .font(.caption2.monospaced())
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                }
            }
        }

        Text("This call has not executed yet. Approve only if the tool and arguments match your intent.")
            .font(.caption2)
            .foregroundStyle(.secondary)

        HStack {
            Button("Approve") {
                model.approvePendingAgentCall()
            }
            .disabled(model.isAgentRunning)

            Button("Reject", role: .destructive) {
                model.rejectPendingAgentCall()
            }
            .disabled(model.isAgentRunning)
        }
    }

    private func renderToolValue(_ value: ToolValue) -> String {
        switch value {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        case .array(let values): return "[" + values.map(renderToolValue).joined(separator: ", ") + "]"
        case .object(let object):
            return "{" + object.keys.sorted().map { key in
                "\(key): \(renderToolValue(object[key] ?? .null))"
            }.joined(separator: ", ") + "}"
        case .null: return "null"
        }
    }
}
#endif
