import Foundation
import XCTest
@testable import LumiCore

final class TaskStoreTests: XCTestCase {
    func testCreatePersistsWithAuditAndSurvivesReopen() async throws {
        let url = try temporaryDatabaseURL()
        let origin = TaskOrigin(conversationID: UUID(), messageID: UUID())
        let firstStore = try SQLiteTaskStore(url: url)
        let created = try await firstStore.create(
            TaskCreateRequest(
                title: "  Durable task  ",
                instruction: "  Keep this across restart.  ",
                maxAttempts: 3,
                origin: origin,
                actor: .user
            )
        )

        XCTAssertEqual(created.title, "Durable task")
        XCTAssertEqual(created.instruction, "Keep this across restart.")
        XCTAssertEqual(created.state, .draft)
        XCTAssertEqual(created.revision, 1)
        XCTAssertEqual(created.attemptCount, 0)
        XCTAssertEqual(created.origin, origin)

        let events = try await firstStore.events(taskID: created.id, limit: 20)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .created)
        XCTAssertEqual(events[0].actor, .user)
        XCTAssertNil(events[0].fromState)
        XCTAssertEqual(events[0].toState, .draft)
        XCTAssertEqual(events[0].revision, 1)

        let reopened = try SQLiteTaskStore(url: url)
        let loadedValue = try await reopened.load(id: created.id)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded, created)
        let reopenedEvents = try await reopened.events(taskID: created.id, limit: 20)
        XCTAssertEqual(reopenedEvents, events)
    }

    func testLegalTransitionsIncrementRevisionAndAttemptsOnlyOnNewRun() async throws {
        let store = try SQLiteTaskStore(url: try temporaryDatabaseURL())
        let created = try await makeTask(store: store, maxAttempts: 3)

        let ready = try await store.transition(
            TaskTransitionRequest(
                id: created.id,
                toState: .ready,
                expectedRevision: created.revision,
                actor: .user,
                reason: "Ready to execute"
            )
        )
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.revision, 2)
        XCTAssertEqual(ready.attemptCount, 0)

        let running = try await store.transition(
            TaskTransitionRequest(
                id: ready.id,
                toState: .running,
                expectedRevision: ready.revision,
                actor: .runner
            )
        )
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.revision, 3)
        XCTAssertEqual(running.attemptCount, 1)

        let waiting = try await store.transition(
            TaskTransitionRequest(
                id: running.id,
                toState: .waitingForPermission,
                expectedRevision: running.revision,
                actor: .runner,
                reason: "Protected tool needs approval"
            )
        )
        let resumed = try await store.transition(
            TaskTransitionRequest(
                id: waiting.id,
                toState: .running,
                expectedRevision: waiting.revision,
                actor: .runner,
                reason: "Permission resolved"
            )
        )
        XCTAssertEqual(resumed.attemptCount, 1)

        let succeeded = try await store.transition(
            TaskTransitionRequest(
                id: resumed.id,
                toState: .succeeded,
                expectedRevision: resumed.revision,
                actor: .runner,
                resultSummary: "Completed"
            )
        )
        XCTAssertEqual(succeeded.resultSummary, "Completed")
        XCTAssertNil(succeeded.lastError)

        let events = try await store.events(taskID: created.id, limit: 20)
        XCTAssertEqual(events.map(\.revision), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(events.last?.toState, .succeeded)
    }

    func testIllegalTransitionAndStaleRevisionFailClosedWithoutExtraAuditEvent() async throws {
        let store = try SQLiteTaskStore(url: try temporaryDatabaseURL())
        let created = try await makeTask(store: store)

        do {
            _ = try await store.transition(
                TaskTransitionRequest(
                    id: created.id,
                    toState: .succeeded,
                    expectedRevision: created.revision,
                    actor: .user
                )
            )
            XCTFail("draft → succeeded must fail")
        } catch let error as TaskStoreError {
            XCTAssertEqual(error, .invalidTransition(from: .draft, to: .succeeded))
        }
        let afterIllegalTransition = try await store.events(taskID: created.id, limit: 20)
        XCTAssertEqual(afterIllegalTransition.count, 1)

        let ready = try await store.transition(
            TaskTransitionRequest(
                id: created.id,
                toState: .ready,
                expectedRevision: created.revision,
                actor: .user
            )
        )
        do {
            _ = try await store.edit(
                TaskEditRequest(
                    id: ready.id,
                    title: "Stale edit",
                    instruction: ready.instruction,
                    maxAttempts: ready.maxAttempts,
                    nextEligibleAt: nil,
                    expectedRevision: created.revision,
                    actor: .user
                )
            )
            XCTFail("stale revision must not overwrite newer state")
        } catch let error as TaskStoreError {
            XCTAssertEqual(
                error,
                .revisionConflict(
                    taskID: ready.id,
                    expected: created.revision,
                    actual: ready.revision
                )
            )
        }
        let afterStaleEdit = try await store.events(taskID: created.id, limit: 20)
        XCTAssertEqual(afterStaleEdit.count, 2)
    }

    func testRunningTaskCannotBeEditedAndCancelledTaskCannotRestart() async throws {
        let store = try SQLiteTaskStore(url: try temporaryDatabaseURL())
        let created = try await makeTask(store: store)
        let ready = try await transition(store, created, to: .ready, actor: .user)
        let running = try await transition(store, ready, to: .running, actor: .runner)

        do {
            _ = try await store.edit(
                TaskEditRequest(
                    id: running.id,
                    title: "Mutated while running",
                    instruction: running.instruction,
                    maxAttempts: running.maxAttempts,
                    nextEligibleAt: nil,
                    expectedRevision: running.revision,
                    actor: .user
                )
            )
            XCTFail("running task must not be editable")
        } catch let error as TaskStoreError {
            XCTAssertEqual(error, .notEditable(.running))
        }

        let cancelled = try await transition(store, running, to: .cancelled, actor: .user)
        do {
            _ = try await transition(store, cancelled, to: .ready, actor: .user)
            XCTFail("cancelled task must stay terminal")
        } catch let error as TaskStoreError {
            XCTAssertEqual(error, .invalidTransition(from: .cancelled, to: .ready))
        }
    }

    func testRetryBudgetIsHardBound() async throws {
        let store = try SQLiteTaskStore(url: try temporaryDatabaseURL())
        let created = try await makeTask(store: store, maxAttempts: 2)
        var task = try await transition(store, created, to: .ready, actor: .user)

        for attempt in 1...2 {
            task = try await transition(store, task, to: .running, actor: .runner)
            XCTAssertEqual(task.attemptCount, attempt)
            task = try await store.transition(
                TaskTransitionRequest(
                    id: task.id,
                    toState: .failed,
                    expectedRevision: task.revision,
                    actor: .runner,
                    lastError: "attempt \(attempt) failed"
                )
            )
            XCTAssertEqual(task.state, .failed)
            if attempt == 1 {
                task = try await transition(store, task, to: .ready, actor: .user)
            }
        }

        do {
            _ = try await transition(store, task, to: .ready, actor: .user)
            XCTFail("retry beyond maxAttempts must fail")
        } catch let error as TaskStoreError {
            XCTAssertEqual(error, .maxAttemptsReached(2))
        }
    }

    func testFutureEligibilityBlocksRunWithoutConsumingAttempt() async throws {
        let store = try SQLiteTaskStore(url: try temporaryDatabaseURL())
        let future = Date().addingTimeInterval(3_600)
        let created = try await store.create(
            TaskCreateRequest(
                title: "Future task",
                instruction: "Do not run early",
                maxAttempts: 2,
                nextEligibleAt: future,
                actor: .user
            )
        )
        let ready = try await transition(store, created, to: .ready, actor: .user)

        do {
            _ = try await transition(store, ready, to: .running, actor: .runner)
            XCTFail("future task must not start early")
        } catch let error as TaskStoreError {
            guard case .notYetEligible = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let unchangedValue = try await store.load(id: ready.id)
        let unchanged = try XCTUnwrap(unchangedValue)
        XCTAssertEqual(unchanged.state, .ready)
        XCTAssertEqual(unchanged.attemptCount, 0)
        XCTAssertEqual(unchanged.revision, ready.revision)
    }

    func testRecoveryTurnsRunningAndWaitingIntoInterruptedWithoutAutoResume() async throws {
        let url = try temporaryDatabaseURL()
        let store = try SQLiteTaskStore(url: url)

        let first = try await makeTask(store: store)
        let firstReady = try await transition(store, first, to: .ready, actor: .user)
        let firstRunning = try await transition(store, firstReady, to: .running, actor: .runner)

        let second = try await makeTask(store: store)
        let secondReady = try await transition(store, second, to: .ready, actor: .user)
        let secondRunning = try await transition(store, secondReady, to: .running, actor: .runner)
        let secondWaiting = try await transition(store, secondRunning, to: .waitingForPermission, actor: .runner)

        let recovered = try await store.recoverInterruptedTasks()
        XCTAssertEqual(Set(recovered.map(\.id)), Set([firstRunning.id, secondWaiting.id]))
        XCTAssertTrue(recovered.allSatisfy { $0.state == .interrupted })
        XCTAssertEqual(recovered.first(where: { $0.id == firstRunning.id })?.attemptCount, 1)
        XCTAssertEqual(recovered.first(where: { $0.id == secondWaiting.id })?.attemptCount, 1)

        let secondRecovery = try await store.recoverInterruptedTasks()
        XCTAssertTrue(secondRecovery.isEmpty)

        for task in recovered {
            let events = try await store.events(taskID: task.id, limit: 20)
            XCTAssertEqual(events.last?.kind, .recovered)
            XCTAssertEqual(events.last?.actor, .recovery)
            XCTAssertEqual(events.last?.toState, .interrupted)
        }

        let reopened = try SQLiteTaskStore(url: url)
        let firstReopenedValue = try await reopened.load(id: firstRunning.id)
        let secondReopenedValue = try await reopened.load(id: secondWaiting.id)
        let firstReopened = try XCTUnwrap(firstReopenedValue)
        let secondReopened = try XCTUnwrap(secondReopenedValue)
        XCTAssertEqual(firstReopened.state, .interrupted)
        XCTAssertEqual(secondReopened.state, .interrupted)
    }

    func testEditPreservesIdentityAndOriginButAdvancesRevision() async throws {
        let store = try SQLiteTaskStore(url: try temporaryDatabaseURL())
        let origin = TaskOrigin(conversationID: UUID(), messageID: UUID())
        let created = try await store.create(
            TaskCreateRequest(
                title: "Original",
                instruction: "Original instruction",
                maxAttempts: 3,
                origin: origin,
                actor: .user
            )
        )
        let edited = try await store.edit(
            TaskEditRequest(
                id: created.id,
                title: "Edited",
                instruction: "Edited instruction",
                maxAttempts: 4,
                nextEligibleAt: nil,
                expectedRevision: created.revision,
                actor: .user,
                reason: "User changed scope"
            )
        )

        XCTAssertEqual(edited.id, created.id)
        XCTAssertEqual(edited.origin, origin)
        XCTAssertEqual(edited.createdAt, created.createdAt)
        XCTAssertEqual(edited.revision, 2)
        XCTAssertEqual(edited.title, "Edited")
        XCTAssertEqual(edited.maxAttempts, 4)
        let events = try await store.events(taskID: created.id, limit: 20)
        XCTAssertEqual(events.last?.kind, .edited)
        XCTAssertEqual(events.last?.reason, "User changed scope")
    }

    private func makeTask(
        store: SQLiteTaskStore,
        maxAttempts: Int = 3
    ) async throws -> TaskRecord {
        try await store.create(
            TaskCreateRequest(
                title: "Task",
                instruction: "Perform deterministic work",
                maxAttempts: maxAttempts,
                actor: .user
            )
        )
    }

    private func transition(
        _ store: SQLiteTaskStore,
        _ task: TaskRecord,
        to state: TaskState,
        actor: TaskMutationActor
    ) async throws -> TaskRecord {
        try await store.transition(
            TaskTransitionRequest(
                id: task.id,
                toState: state,
                expectedRevision: task.revision,
                actor: actor
            )
        )
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiTaskStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("tasks.sqlite3")
    }
}
