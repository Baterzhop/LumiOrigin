#if canImport(SwiftUI)
import SwiftUI
import LumiCore

struct RuntimeDiagnosticsSection: View {
    @StateObject private var model = RuntimeDiagnosticsViewModel()

    var body: some View {
        Section("Local Runtime") {
            HStack {
                if let report = model.report {
                    Label(readinessLabel(report.readiness), systemImage: readinessIcon(report.readiness))
                        .font(.caption.weight(.semibold))
                } else {
                    Text("Not checked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isChecking {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isChecking)
                .help("Refresh local runtime diagnostics")
            }

            if let report = model.report {
                LabeledContent("Ollama", value: report.ollamaReachable ? "reachable" : "unavailable")
                    .font(.caption)

                if let chat = report.modelRoutes.first(where: { $0.role == .chat }) {
                    modelRow(label: "Chat", diagnostic: chat)
                }

                HStack {
                    Text("Embeddings")
                    Spacer()
                    Text(report.embeddingModel)
                        .lineLimit(1)
                    Image(systemName: report.embeddingInstalled ? "checkmark.circle" : "exclamationmark.triangle")
                }
                .font(.caption)

                if report.readiness == .degraded {
                    Text("Lumi can run, but one or more specialized/embedding models are missing. Generation routes fall back to the chat model; RAG can fall back to sparse search.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if report.readiness == .unavailable {
                    Text("Generated answers will use deterministic fallback until Ollama and the configured chat model are available.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Model routes") {
                    ForEach(report.modelRoutes) { route in
                        modelRow(label: roleLabel(route.role), diagnostic: route)
                    }
                }
                .font(.caption)

                DisclosureGroup("Configuration") {
                    configLine("Chat API", report.chatEndpoint)
                    configLine("Embed API", report.embeddingEndpoint)
                    configLine("Tags API", report.tagsEndpoint)
                    configLine("Context", "\(report.contextWindow) tokens")
                    if let workspacePath = report.workspacePath {
                        configLine("Workspace", workspacePath)
                    }
                    if let databasePath = report.databasePath {
                        configLine("Database", databasePath)
                    }
                }
                .font(.caption)

                if let issue = report.issue, !issue.isEmpty {
                    Text(issue)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(5)
                        .textSelection(.enabled)
                }

                Text("Checked \(report.checkedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func modelRow(label: String, diagnostic: RuntimeModelDiagnostic) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(diagnostic.configuredModel)
                .lineLimit(1)
            Image(systemName: diagnostic.installed ? "checkmark.circle" : "exclamationmark.triangle")
        }
        .font(.caption)

        if !diagnostic.installed && diagnostic.usesChatFallbackWhenMissing {
            Text("\(label) falls back to Chat")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func configLine(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func roleLabel(_ role: ModelRole) -> String {
        switch role {
        case .chat: return "Chat"
        case .knowledge: return "Knowledge"
        case .coding: return "Coding"
        case .reflection: return "Reflection"
        case .agentPlanner: return "Agent planner"
        }
    }

    private func readinessLabel(_ readiness: LocalRuntimeReadiness) -> String {
        switch readiness {
        case .ready: return "Ready"
        case .degraded: return "Degraded"
        case .unavailable: return "Unavailable"
        }
    }

    private func readinessIcon(_ readiness: LocalRuntimeReadiness) -> String {
        switch readiness {
        case .ready: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .unavailable: return "xmark.circle.fill"
        }
    }
}
#endif
