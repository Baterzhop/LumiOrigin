#if canImport(SwiftUI)
import Foundation
import LumiCore

@MainActor
extension LumiAppModel {
    func createTask(title: String, instruction: String, maxAttempts: Int = 3) {
        guard
            !isSafeMode,
            !isSending,
            pendingApproval == nil,
            let taskService
        else { return }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty, !normalizedInstruction.isEmpty else { return }

        isSending = true
        lastError = nil
        status = "Creating task…"
        Task {
            defer { isSending = false }
            do {
                let record = try await taskService.create(
                    title: normalizedTitle,
                    instruction: normalizedInstruction,
                    maxAttempts: maxAttempts,
                    actor: .user
                )
                selectedTaskID = record.id
                await refreshTasksAndSelection(reconfigureRuntime: true)
                status = "Task created as draft"
            } catch {
                status = "Task creation failed"
                lastError = String(describing: error)
                await refreshTasksAndSelection()
            }
        }
    }

    func updateTask(
        _ record: TaskRecord,
        title: String,
        instruction: String,
        maxAttempts: Int
    ) {
        guard
            !isSafeMode,
            !isSending,
            pendingApproval == nil,
            let taskService
        else { return }

        isSending = true
        lastError = nil
        status = "Updating task…"
        Task {
            defer { isSending = false }
            do {
                _ = try await taskService.edit(
                    id: record.id,
                    title: title,
                    instruction: instruction,
                    maxAttempts: maxAttempts,
                    nextEligibleAt: record.nextEligibleAt,
                    expectedRevision: record.revision,
                    actor: .user,
                    reason: "Edited directly in Lumi Tasks UI"
                )
                selectedTaskID = record.id
                await refreshTasksAndSelection(reconfigureRuntime: true)
                status = "Task updated"
            } catch {
                status = "Task update failed"
                lastError = String(describing: error)
                await refreshTasksAndSelection()
            }
        }
    }

    func markTaskReady(_ record: TaskRecord) {
        guard
            !isSafeMode,
            !isSending,
            pendingApproval == nil,
            record.state == .draft,
            let taskService
        else { return }

        isSending = true
        lastError = nil
        status = "Marking task ready…"
        Task {
            defer { isSending = false }
            do {
                _ = try await taskService.transition(
                    id: record.id,
                    to: .ready,
                    expectedRevision: record.revision,
                    actor: .user,
                    reason: "User marked task ready"
                )
                selectedTaskID = record.id
                await refreshTasksAndSelection(reconfigureRuntime: true)
                status = "Task ready"
            } catch {
                status = "Task transition failed"
                lastError = String(describing: error)
                await refreshTasksAndSelection()
            }
        }
    }

    func startTask(_ record: TaskRecord) {
        guard
            !isSafeMode,
            !isSending,
            pendingApproval == nil,
            record.state == .ready,
            let taskRunner
        else { return }

        isSending = true
        lastError = nil
        status = "Running task…"
        selectedTaskID = record.id
        Task {
            defer { isSending = false }
            do {
                let outcome = try await taskRunner.start(
                    taskID: record.id,
                    expectedRevision: record.revision
                )
                await applyTaskRunOutcome(outcome)
            } catch {
                status = "Task start failed"
                lastError = String(describing: error)
                await refreshTasksAndSelection()
            }
        }
    }

    func resumeTask(_ record: TaskRecord) {
        guard
            !isSafeMode,
            !isSending,
            pendingApproval == nil,
            record.state == .failed || record.state == .interrupted,
            let taskRunner
        else { return }

        isSending = true
        lastError = nil
        status = "Resuming task…"
        selectedTaskID = record.id
        Task {
            defer { isSending = false }
            do {
                let outcome = try await taskRunner.resume(
                    taskID: record.id,
                    expectedRevision: record.revision
                )
                await applyTaskRunOutcome(outcome)
            } catch {
                status = "Task resume failed"
                lastError = String(describing: error)
                await refreshTasksAndSelection()
            }
        }
    }

    func cancelTask(_ record: TaskRecord) {
        guard
            !isSafeMode,
            !isSending,
            record.state != .succeeded,
            record.state != .cancelled,
            let taskRunner
        else { return }

        // Cancellation is allowed even when the current permission panel belongs
        // to this task. TaskRunner abandons that process-local continuation first.
        if let owner = pendingTaskApprovalID, owner != record.id {
            return
        }

        isSending = true
        lastError = nil
        status = "Cancelling task…"
        Task {
            defer { isSending = false }
            do {
                _ = try await taskRunner.cancel(
                    taskID: record.id,
                    expectedRevision: record.revision,
                    reason: "Cancelled directly in Lumi Tasks UI"
                )
                if pendingTaskApprovalID == record.id {
                    pendingApproval = nil
                    pendingTaskApprovalID = nil
                    pendingMemoryExisting = nil
                }
                selectedTaskID = record.id
                await refreshTasksAndSelection(reconfigureRuntime: true)
                status = "Task cancelled"
            } catch {
                status = "Task cancellation failed"
                lastError = String(describing: error)
                await refreshTasksAndSelection()
            }
        }
    }

    func selectTask(_ record: TaskRecord) {
        selectedTaskID = record.id
        Task { await refreshSelectedTaskEvents() }
    }

    func refreshTasksAndSelection(reconfigureRuntime: Bool = false) async {
        guard let taskService else {
            tasks = []
            selectedTaskEvents = []
            return
        }
        do {
            tasks = try await taskService.list(limit: 100)
            if let selectedTaskID,
               !tasks.contains(where: { $0.id == selectedTaskID }) {
                self.selectedTaskID = nil
            }
            await refreshSelectedTaskEvents()
            if reconfigureRuntime {
                reconfigureRuntimeForCurrentResources()
            }
        } catch {
            lastError = "Task refresh failed: \(error)"
        }
    }

    func refreshSelectedTaskEvents() async {
        guard let selectedTaskID, let taskService else {
            selectedTaskEvents = []
            return
        }
        do {
            selectedTaskEvents = try await taskService.events(
                taskID: selectedTaskID,
                limit: 100
            )
        } catch {
            selectedTaskEvents = []
            lastError = "Task audit refresh failed: \(error)"
        }
    }

    func applyTaskRunOutcome(_ outcome: TaskRunOutcome) async {
        switch outcome {
        case .completed(let task, let response):
            pendingApproval = nil
            pendingTaskApprovalID = nil
            pendingMemoryExisting = nil
            selectedTaskID = task.id
            lastCitations = response.citations
            status = "Task completed"
            await refreshTasksAndSelection(reconfigureRuntime: true)

        case .permissionRequired(let task, let approval):
            selectedTaskID = task.id
            pendingApproval = approval
            pendingTaskApprovalID = task.id
            pendingMemoryExisting = nil
            status = "Task waiting for permission"
            await refreshTasksAndSelection()

        case .failed(let task, let message):
            pendingApproval = nil
            pendingTaskApprovalID = nil
            pendingMemoryExisting = nil
            selectedTaskID = task.id
            status = "Task failed"
            lastError = message
            await refreshTasksAndSelection(reconfigureRuntime: true)

        case .cancelled(let task):
            pendingApproval = nil
            pendingTaskApprovalID = nil
            pendingMemoryExisting = nil
            selectedTaskID = task.id
            status = "Task cancelled"
            await refreshTasksAndSelection(reconfigureRuntime: true)
        }
    }
}
#endif
