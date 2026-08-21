import AppKit
import SwiftUI

struct LumiReadinessView: View {
    @ObservedObject var coreManager: CoreProcessManager
    @State private var isRunning = false
    @State private var requireModel = true
    @State private var headline = "Not tested on this Mac yet."
    @State private var detail = "Run the readiness check against the installed Core and the model configured in Lumi Settings."
    @State private var rawOutput = ""
    @State private var passed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lumi Readiness Center")
                        .font(.title2.weight(.semibold))
                    Text("Machine-local acceptance for Core, real-model chat, SSE, RAG, memory, tools and verified backup.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: passed ? "checkmark.seal.fill" : "checklist")
                    .font(.system(size: 34))
                    .foregroundStyle(passed ? .green : .secondary)
            }

            GroupBox("Acceptance mode") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Require the configured real model (fallback must be false)", isOn: $requireModel)
                    Text(requireModel
                         ? "Use this for the Lumi 4.0.0 target-Mac gate."
                         : "This mode validates the application plumbing even when Ollama is unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Result") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if isRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: passed ? "checkmark.circle.fill" : "info.circle")
                                .foregroundStyle(passed ? .green : .secondary)
                        }
                        Text(headline).font(.headline)
                    }
                    Text(detail)
                        .font(.callout)
                        .textSelection(.enabled)
                    if !rawOutput.isEmpty {
                        ScrollView {
                            Text(rawOutput)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 180)
                        .padding(8)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("What remains outside this check") {
                Text("Apple Developer-ID signing, notarization and Gatekeeper verification require Apple credentials and a distribution target. They are deliberately not reported as passed by a local runtime test.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Run readiness check") {
                    Task { await runAcceptance() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)

                Button("Copy result") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rawOutput.isEmpty ? "\(headline)\n\(detail)" : rawOutput, forType: .string)
                }
                .disabled(rawOutput.isEmpty && headline.isEmpty)

                Spacer()
                Text("Core: \(coreManager.detail)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 620)
    }

    @MainActor
    private func runAcceptance() async {
        guard !isRunning else { return }
        isRunning = true
        passed = false
        headline = "Preparing Lumi Core…"
        detail = "Checking the configured runtime before starting acceptance."
        rawOutput = ""

        await coreManager.ensureRunning()
        switch coreManager.state {
        case .connected, .runningManaged:
            break
        default:
            headline = "Core is not ready"
            detail = coreManager.detail
            isRunning = false
            return
        }

        headline = "Running acceptance…"
        detail = requireModel
            ? "Real model is required; any fallback will fail the gate."
            : "Fallback is allowed for this plumbing-only run."

        do {
            let run = try await LumiAcceptanceRunner.run(requireModel: requireModel)
            rawOutput = run.rawOutput
            passed = run.report.ok && (!requireModel || !run.report.fallback)
            headline = passed ? "Acceptance passed on this Mac" : "Acceptance did not satisfy the selected gate"
            let provider = run.report.chatProvider ?? "unknown"
            let model = run.report.chatModel ?? "unknown"
            detail = "Provider: \(provider) · model: \(model) · fallback: \(run.report.fallback ? "yes" : "no") · SSE completed: \(run.report.streamEvents.contains("completed") ? "yes" : "no")"
        } catch {
            passed = false
            headline = "Acceptance failed"
            detail = error.localizedDescription
            rawOutput = error.localizedDescription
        }
        isRunning = false
    }
}
