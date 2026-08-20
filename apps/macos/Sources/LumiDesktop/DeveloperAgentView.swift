import SwiftUI
import LumiClientCore

struct DeveloperAgentView: View {
    @StateObject private var model = DeveloperViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lumi Developer Agent")
                        .font(.title2.weight(.semibold))
                    Text("Plan → explicit approval → isolated branch → validation → explicit publish approval → draft PR")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }
            }

            statusPanel
            Divider()

            if model.session == nil {
                proposalForm
            } else if let session = model.session {
                sessionView(session)
            }
        }
        .padding(18)
        .frame(minWidth: 820, minHeight: 680)
        .task { await model.refresh() }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.statusText)
                .font(.headline)
            if let status = model.status {
                HStack(spacing: 18) {
                    LabeledContent("Enabled", value: status.enabled ? "yes" : "no")
                    LabeledContent("Repository", value: status.repositoryOK ? "ready" : "not ready")
                    LabeledContent("Clean", value: status.clean ? "yes" : "no")
                    LabeledContent("Local checks", value: status.localChecksEnabled ? "enabled" : "disabled")
                    LabeledContent("PR publisher", value: status.publisherConfigured ? "configured" : "not configured")
                }
                .font(.caption)
                if !status.localChecksEnabled {
                    Text("Local validation is disabled by default because tests execute code from the developer checkout. If a proposal requires checks, Lumi stops at validation_incomplete and blocks publishing.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let root = status.repositoryRoot {
                    Text(root)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let branch = status.currentBranch {
                    Text("Current branch: \(branch) · base: \(status.baseBranch)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var proposalForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New change proposal").font(.headline)
            Text("Lumi only inspects the configured separate Git checkout at this stage. It cannot modify the running application source tree directly.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $model.goal)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Propose change") { model.propose() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isWorking
                        || model.status?.enabled != true
                        || model.status?.repositoryOK != true
                        || model.status?.clean != true
                    )
            }
        }
    }

    @ViewBuilder
    private func sessionView(_ session: DeveloperSessionDTO) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(session.proposal?.summary ?? session.goal)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text(session.status)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                if let rationale = session.proposal?.rationale {
                    Text(rationale)
                        .textSelection(.enabled)
                }

                if let proposal = session.proposal {
                    GroupBox("Exact proposed file operations") {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(proposal.changes) { change in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(change.operation.uppercased())
                                            .font(.caption2.monospaced().weight(.bold))
                                        Text(change.path)
                                            .font(.caption.monospaced())
                                    }
                                    Text(change.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let diff = session.proposedDiff, !diff.isEmpty {
                    GroupBox("Diff") {
                        ScrollView([.vertical, .horizontal]) {
                            Text(diff)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 220, maxHeight: 340)
                    }
                }

                if !session.checks.isEmpty {
                    GroupBox("Required validation") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(session.checks, id: \.self) { check in
                                Text("• \(check)").font(.caption.monospaced())
                            }
                            Text("These are fixed allow-listed profiles; the model cannot supply an arbitrary shell command.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if model.status?.localChecksEnabled != true {
                                Text("Local checks are currently disabled. Approving the plan may apply the change on an isolated branch, but publishing remains blocked until required checks can run successfully.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !session.validation.isEmpty {
                    GroupBox("Validation") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(session.validation) { result in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(result.name): \(result.status)")
                                        .font(.caption.weight(.semibold))
                                    if !result.command.isEmpty {
                                        Text(result.command.joined(separator: " "))
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    if result.status != "passed" && !result.output.isEmpty {
                                        Text(result.output)
                                            .font(.caption2.monospaced())
                                            .textSelection(.enabled)
                                            .lineLimit(12)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let branch = session.branchName {
                    Text("Developer branch: \(branch)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let commit = session.commitSHA {
                    Text("Commit: \(commit)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let url = session.prURL, let link = URL(string: url) {
                    Link("Open draft pull request", destination: link)
                }
                if let error = session.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                actionBar(session)
            }
        }
    }

    @ViewBuilder
    private func actionBar(_ session: DeveloperSessionDTO) -> some View {
        HStack {
            Button("New session") { model.reset() }
                .disabled(model.isWorking)
            Spacer()

            if session.status == "awaiting_plan_approval" {
                Button("Deny", role: .destructive) { model.denyPlan() }
                    .disabled(model.isWorking)
                Button("Approve exact plan") { model.approvePlan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
            } else if ["validation_failed", "validation_incomplete"].contains(session.status) {
                Button("Run validation again") { model.revalidate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking || model.status?.localChecksEnabled != true)
                    .help("Runs only Lumi's fixed validation profiles; requires LUMI_DEV_ALLOW_LOCAL_CHECKS=true")
            } else if ["ready_to_publish", "publish_failed"].contains(session.status) {
                Button("Publish branch + create draft PR") { model.publish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking || model.status?.publisherConfigured != true)
            }
        }
        .padding(.top, 4)
    }
}
