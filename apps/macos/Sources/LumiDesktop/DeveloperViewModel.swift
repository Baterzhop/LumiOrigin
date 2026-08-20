import Foundation
import SwiftUI
import LumiClientCore

@MainActor
final class DeveloperViewModel: ObservableObject {
    @Published var goal = ""
    @Published private(set) var status: DeveloperStatusDTO?
    @Published private(set) var session: DeveloperSessionDTO?
    @Published private(set) var statusText = "Checking Developer Agent…"
    @Published private(set) var isWorking = false

    private let api: LumiAPIClient

    init(api: LumiAPIClient = LumiAPIClient()) {
        self.api = api
    }

    func refresh() async {
        do {
            status = try await api.developerStatus()
            if status?.enabled == true {
                statusText = status?.repositoryOK == true ? "Developer Agent ready" : "Repository unavailable"
            } else {
                statusText = status?.error ?? "Developer Agent disabled"
            }
        } catch {
            statusText = "Developer Agent offline: \(error.localizedDescription)"
        }
    }

    func propose() {
        let clean = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isWorking else { return }
        isWorking = true
        statusText = "Inspecting repository and proposing a change…"
        Task {
            do {
                session = try await api.createDeveloperSession(goal: clean)
                statusText = describe(session)
            } catch {
                statusText = "Proposal failed: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    func approvePlan() {
        guard let id = session?.id, session?.status == "awaiting_plan_approval", !isWorking else { return }
        isWorking = true
        statusText = "Applying approved proposal and running bounded checks…"
        Task {
            do {
                session = try await api.approveDeveloperPlan(id)
                statusText = describe(session)
            } catch {
                statusText = "Apply/validation failed: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    func denyPlan() {
        guard let id = session?.id, session?.status == "awaiting_plan_approval", !isWorking else { return }
        isWorking = true
        Task {
            do {
                session = try await api.denyDeveloperPlan(id)
                statusText = describe(session)
            } catch {
                statusText = "Denial failed: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    func publish() {
        guard let id = session?.id, ["ready_to_publish", "publish_failed"].contains(session?.status ?? ""), !isWorking else { return }
        isWorking = true
        statusText = "Publishing approved branch and opening a draft PR…"
        Task {
            do {
                session = try await api.publishDeveloperSession(id)
                statusText = describe(session)
            } catch {
                statusText = "Publish failed: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    func reset() {
        guard !isWorking else { return }
        session = nil
        goal = ""
        statusText = status?.enabled == true ? "Developer Agent ready" : (status?.error ?? "Developer Agent disabled")
    }

    private func describe(_ session: DeveloperSessionDTO?) -> String {
        guard let session else { return "No developer session" }
        switch session.status {
        case "awaiting_plan_approval":
            return "Review the exact proposal and diff before approving."
        case "ready_to_publish":
            return "Checks passed. Review the diff again before publishing the draft PR."
        case "validation_failed":
            return "Validation failed. Nothing was pushed or published."
        case "published":
            return "Draft pull request created. Lumi did not merge it."
        case "denied":
            return "Proposal denied. Repository was not changed."
        case "publish_failed":
            return "Publish failed; the local developer branch remains auditable."
        case "failed":
            return "Developer workflow failed: \(session.error ?? "unknown error")"
        default:
            return session.status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
