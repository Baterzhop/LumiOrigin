import Foundation
import CSQLite

private final class TaskSQLiteConnection: @unchecked Sendable {
    let raw: OpaquePointer

    init(raw: OpaquePointer) {
        self.raw = raw
    }

    deinit {
        sqlite3_close_v2(raw)
    }
}

/// Durable TaskEngine persistence. Every task mutation and its audit event are
/// committed in one SQLite transaction. Task text is durable user data only;
/// this store never persists permission grants or execution authority.
public actor SQLiteTaskStore: TaskStore {
    private let connection: TaskSQLiteConnection
    private let stateMachine = TaskStateMachine()

    public init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var rawHandle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &rawHandle, flags, nil)

        guard result == SQLITE_OK, let rawHandle else {
            let message = rawHandle
                .flatMap { sqlite3_errmsg($0) }
                .map { String(cString: $0) }
                ?? "unknown error"
            if let rawHandle { sqlite3_close_v2(rawHandle) }
            throw TaskStoreError.openFailed(message)
        }

        do {
            try Self.execute(rawHandle, sql: "PRAGMA foreign_keys = ON;")
            try Self.execute(rawHandle, sql: "PRAGMA journal_mode = WAL;")
            try Self.execute(rawHandle, sql: "PRAGMA synchronous = NORMAL;")
            try Self.execute(rawHandle, sql: Self.schema)
            connection = TaskSQLiteConnection(raw: rawHandle)
        } catch {
            sqlite3_close_v2(rawHandle)
            throw error
        }
    }

    public func create(_ request: TaskCreateRequest) async throws -> TaskRecord {
        let title = try TaskValidation.title(request.title)
        let instruction = try TaskValidation.instruction(request.instruction)
        let maxAttempts = try TaskValidation.maxAttempts(request.maxAttempts)
        let db = connection.raw
        let now = Self.persistenceDate()
        let record = TaskRecord(
            id: TaskID(),
            title: title,
            instruction: instruction,
            state: .draft,
            revision: 1,
            attemptCount: 0,
            maxAttempts: maxAttempts,
            nextEligibleAt: request.nextEligibleAt.map(Self.persistenceDate),
            lastError: nil,
            resultSummary: nil,
            origin: request.origin,
            createdAt: now,
            updatedAt: now
        )
        let event = TaskEvent(
            taskID: record.id,
            revision: record.revision,
            kind: .created,
            actor: request.actor,
            fromState: nil,
            toState: .draft,
            reason: nil,
            createdAt: now
        )

        try Self.execute(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try insertTask(record, db: db)
            try insertEvent(event, db: db)
            try Self.execute(db, sql: "COMMIT;")
            return record
        } catch {
            try? Self.execute(db, sql: "ROLLBACK;")
            throw error
        }
    }

    public func load(id: TaskID) async throws -> TaskRecord? {
        try fetchTask(id: id, db: connection.raw)
    }

    public func list(limit: Int) async throws -> [TaskRecord] {
        guard (1...500).contains(limit) else {
            throw TaskStoreError.executionFailed("task list limit must be 1...500")
        }
        let db = connection.raw
        let sql = Self.taskSelect + " ORDER BY updated_at DESC, id ASC LIMIT ?1;"
        var statement: OpaquePointer?
        try prepare(db, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sqlite3_int64(limit))

        var records: [TaskRecord] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                records.append(try decodeTask(statement))
            case SQLITE_DONE:
                return records
            default:
                throw TaskStoreError.executionFailed(errorMessage(db))
            }
        }
    }

    public func events(taskID: TaskID, limit: Int) async throws -> [TaskEvent] {
        guard (1...1_000).contains(limit) else {
            throw TaskStoreError.executionFailed("task event limit must be 1...1000")
        }
        let db = connection.raw
        let sql = """
        SELECT id, task_id, revision, kind, actor, from_state, to_state, reason, created_at
        FROM task_events
        WHERE task_id = ?1
        ORDER BY revision ASC, created_at ASC, id ASC
        LIMIT ?2;
        """
        var statement: OpaquePointer?
        try prepare(db, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bind(taskID.description, to: statement, index: 1)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(limit))

        var result: [TaskEvent] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append(try decodeEvent(statement))
            case SQLITE_DONE:
                return result
            default:
                throw TaskStoreError.executionFailed(errorMessage(db))
            }
        }
    }

    public func edit(_ request: TaskEditRequest) async throws -> TaskRecord {
        let db = connection.raw
        try Self.execute(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            guard let current = try fetchTask(id: request.id, db: db) else {
                throw TaskStoreError.notFound(request.id)
            }
            try validateRevision(current, expected: request.expectedRevision)
            guard current.state.isEditable else {
                throw TaskStoreError.notEditable(current.state)
            }

            let title = try TaskValidation.title(request.title)
            let instruction = try TaskValidation.instruction(request.instruction)
            let maxAttempts = try TaskValidation.maxAttempts(
                request.maxAttempts,
                alreadyAttempted: current.attemptCount
            )
            let reason = try TaskValidation.detail(request.reason)
            let now = Self.persistenceDate()
            let updated = TaskRecord(
                id: current.id,
                title: title,
                instruction: instruction,
                state: current.state,
                revision: current.revision + 1,
                attemptCount: current.attemptCount,
                maxAttempts: maxAttempts,
                nextEligibleAt: request.nextEligibleAt.map(Self.persistenceDate),
                lastError: current.lastError,
                resultSummary: current.resultSummary,
                origin: current.origin,
                createdAt: current.createdAt,
                updatedAt: now
            )
            try updateTask(updated, expectedRevision: current.revision, db: db)
            try insertEvent(
                TaskEvent(
                    taskID: current.id,
                    revision: updated.revision,
                    kind: .edited,
                    actor: request.actor,
                    fromState: current.state,
                    toState: current.state,
                    reason: reason,
                    createdAt: now
                ),
                db: db
            )
            try Self.execute(db, sql: "COMMIT;")
            return updated
        } catch {
            try? Self.execute(db, sql: "ROLLBACK;")
            throw error
        }
    }

    public func transition(_ request: TaskTransitionRequest) async throws -> TaskRecord {
        let db = connection.raw
        try Self.execute(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            guard let current = try fetchTask(id: request.id, db: db) else {
                throw TaskStoreError.notFound(request.id)
            }
            try validateRevision(current, expected: request.expectedRevision)
            let now = Self.persistenceDate()
            try stateMachine.validateTransition(from: current, to: request.toState, now: now)

            let reason = try TaskValidation.detail(request.reason)
            let requestedError = try TaskValidation.detail(request.lastError)
            let requestedResult = try TaskValidation.detail(request.resultSummary)
            let nextAttemptCount = stateMachine.resultingAttemptCount(
                from: current,
                to: request.toState
            )

            let nextError: String?
            let nextResult: String?
            switch request.toState {
            case .succeeded:
                nextError = nil
                nextResult = requestedResult
            case .failed:
                nextError = requestedError ?? reason ?? "Task execution failed."
                nextResult = nil
            case .interrupted:
                nextError = requestedError ?? reason ?? "Task execution was interrupted."
                nextResult = nil
            case .running:
                nextError = current.lastError
                nextResult = nil
            case .draft, .ready, .waitingForPermission, .cancelled:
                nextError = requestedError ?? current.lastError
                nextResult = requestedResult ?? current.resultSummary
            }

            let updated = TaskRecord(
                id: current.id,
                title: current.title,
                instruction: current.instruction,
                state: request.toState,
                revision: current.revision + 1,
                attemptCount: nextAttemptCount,
                maxAttempts: current.maxAttempts,
                nextEligibleAt: current.nextEligibleAt,
                lastError: nextError,
                resultSummary: nextResult,
                origin: current.origin,
                createdAt: current.createdAt,
                updatedAt: now
            )
            try updateTask(updated, expectedRevision: current.revision, db: db)
            try insertEvent(
                TaskEvent(
                    taskID: current.id,
                    revision: updated.revision,
                    kind: .transitioned,
                    actor: request.actor,
                    fromState: current.state,
                    toState: updated.state,
                    reason: reason,
                    createdAt: now
                ),
                db: db
            )
            try Self.execute(db, sql: "COMMIT;")
            return updated
        } catch {
            try? Self.execute(db, sql: "ROLLBACK;")
            throw error
        }
    }

    public func recoverInterruptedTasks() async throws -> [TaskRecord] {
        let db = connection.raw
        try Self.execute(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            let inFlight = try fetchTasks(
                states: [.running, .waitingForPermission],
                db: db
            )
            guard !inFlight.isEmpty else {
                try Self.execute(db, sql: "COMMIT;")
                return []
            }

            var recovered: [TaskRecord] = []
            for current in inFlight {
                let now = Self.persistenceDate()
                try stateMachine.validateTransition(from: current, to: .interrupted, now: now)
                let reason = "Recovered after process restart; execution was not resumed automatically."
                let updated = TaskRecord(
                    id: current.id,
                    title: current.title,
                    instruction: current.instruction,
                    state: .interrupted,
                    revision: current.revision + 1,
                    attemptCount: current.attemptCount,
                    maxAttempts: current.maxAttempts,
                    nextEligibleAt: current.nextEligibleAt,
                    lastError: reason,
                    resultSummary: nil,
                    origin: current.origin,
                    createdAt: current.createdAt,
                    updatedAt: now
                )
                try updateTask(updated, expectedRevision: current.revision, db: db)
                try insertEvent(
                    TaskEvent(
                        taskID: current.id,
                        revision: updated.revision,
                        kind: .recovered,
                        actor: .recovery,
                        fromState: current.state,
                        toState: .interrupted,
                        reason: reason,
                        createdAt: now
                    ),
                    db: db
                )
                recovered.append(updated)
            }

            try Self.execute(db, sql: "COMMIT;")
            return recovered
        } catch {
            try? Self.execute(db, sql: "ROLLBACK;")
            throw error
        }
    }

    private func fetchTask(id: TaskID, db: OpaquePointer) throws -> TaskRecord? {
        let sql = Self.taskSelect + " WHERE id = ?1 LIMIT 1;"
        var statement: OpaquePointer?
        try prepare(db, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bind(id.description, to: statement, index: 1)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeTask(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw TaskStoreError.executionFailed(errorMessage(db))
        }
    }

    private func fetchTasks(states: Set<TaskState>, db: OpaquePointer) throws -> [TaskRecord] {
        let orderedStates = states.map(\.rawValue).sorted()
        guard !orderedStates.isEmpty else { return [] }
        let placeholders = orderedStates.enumerated().map { "?\($0.offset + 1)" }.joined(separator: ",")
        let sql = Self.taskSelect + " WHERE state IN (\(placeholders)) ORDER BY updated_at ASC, id ASC;"
        var statement: OpaquePointer?
        try prepare(db, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        for (offset, state) in orderedStates.enumerated() {
            bind(state, to: statement, index: Int32(offset + 1))
        }

        var records: [TaskRecord] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                records.append(try decodeTask(statement))
            case SQLITE_DONE:
                return records
            default:
                throw TaskStoreError.executionFailed(errorMessage(db))
            }
        }
    }

    private func insertTask(_ record: TaskRecord, db: OpaquePointer) throws {
        let sql = """
        INSERT INTO tasks (
            id, title, instruction, state, revision, attempt_count, max_attempts,
            next_eligible_at, last_error, result_summary, origin_conversation_id,
            origin_message_id, created_at, updated_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14);
        """
        var statement: OpaquePointer?
        try prepare(db, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bindTask(record, to: statement)
        try stepDone(statement, db: db)
    }

    private func updateTask(
        _ record: TaskRecord,
        expectedRevision: Int,
        db: OpaquePointer
    ) throws {
        let sql = """
        UPDATE tasks SET
            title = ?2,
            instruction = ?3,
            state = ?4,
            revision = ?5,
            attempt_count = ?6,
            max_attempts = ?7,
            next_eligible_at = ?8,
            last_error = ?9,
            result_summary = ?10,
            origin_conversation_id = ?11,
            origin_message_id = ?12,
            created_at = ?13,
            updated_at = ?14
        WHERE id = ?1 AND revision = ?15;
        """
        var statement: OpaquePointer?
        try prepare(db, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bindTask(record, to: statement)
        sqlite3_bind_int64(statement, 15, sqlite3_int64(expectedRevision))
        try stepDone(statement, db: db)
        guard sqlite3_changes(db) == 1 else {
            let actual = try fetchTask(id: record.id, db: db)?.revision
            throw TaskStoreError.revisionConflict(
                taskID: record.id,
                expected: expectedRevision,
                actual: actual
            )
        }
    }

    private func insertEvent(_ event: TaskEvent, db: OpaquePointer) throws {
        let sql = """
        INSERT INTO task_events (
            id, task_id, revision, kind, actor, from_state, to_state, reason, created_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);
        """
        var statement: OpaquePointer?
        try prepare(db, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bind(event.id.uuidString.lowercased(), to: statement, index: 1)
        bind(event.taskID.description, to: statement, index: 2)
        sqlite3_bind_int64(statement, 3, sqlite3_int64(event.revision))
        bind(event.kind.rawValue, to: statement, index: 4)
        bind(event.actor.rawValue, to: statement, index: 5)
        bindOptional(event.fromState?.rawValue, to: statement, index: 6)
        bind(event.toState.rawValue, to: statement, index: 7)
        bindOptional(event.reason, to: statement, index: 8)
        sqlite3_bind_double(statement, 9, event.createdAt.timeIntervalSince1970)
        try stepDone(statement, db: db)
    }

    private func bindTask(_ record: TaskRecord, to statement: OpaquePointer?) {
        bind(record.id.description, to: statement, index: 1)
        bind(record.title, to: statement, index: 2)
        bind(record.instruction, to: statement, index: 3)
        bind(record.state.rawValue, to: statement, index: 4)
        sqlite3_bind_int64(statement, 5, sqlite3_int64(record.revision))
        sqlite3_bind_int64(statement, 6, sqlite3_int64(record.attemptCount))
        sqlite3_bind_int64(statement, 7, sqlite3_int64(record.maxAttempts))
        bindOptionalDate(record.nextEligibleAt, to: statement, index: 8)
        bindOptional(record.lastError, to: statement, index: 9)
        bindOptional(record.resultSummary, to: statement, index: 10)
        bindOptional(record.origin.conversationID?.uuidString.lowercased(), to: statement, index: 11)
        bindOptional(record.origin.messageID?.uuidString.lowercased(), to: statement, index: 12)
        sqlite3_bind_double(statement, 13, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 14, record.updatedAt.timeIntervalSince1970)
    }

    private func decodeTask(_ statement: OpaquePointer?) throws -> TaskRecord {
        guard
            let rawID = UUID(uuidString: text(statement, column: 0)),
            let state = TaskState(rawValue: text(statement, column: 3))
        else {
            throw TaskStoreError.corruptData("invalid task identity or state")
        }

        let conversationID = optionalText(statement, column: 10).flatMap(UUID.init(uuidString:))
        let messageID = optionalText(statement, column: 11).flatMap(UUID.init(uuidString:))
        return TaskRecord(
            id: TaskID(rawValue: rawID),
            title: text(statement, column: 1),
            instruction: text(statement, column: 2),
            state: state,
            revision: Int(sqlite3_column_int64(statement, 4)),
            attemptCount: Int(sqlite3_column_int64(statement, 5)),
            maxAttempts: Int(sqlite3_column_int64(statement, 6)),
            nextEligibleAt: optionalDate(statement, column: 7),
            lastError: optionalText(statement, column: 8),
            resultSummary: optionalText(statement, column: 9),
            origin: TaskOrigin(
                conversationID: conversationID,
                messageID: messageID
            ),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13))
        )
    }

    private func decodeEvent(_ statement: OpaquePointer?) throws -> TaskEvent {
        guard
            let eventID = UUID(uuidString: text(statement, column: 0)),
            let rawTaskID = UUID(uuidString: text(statement, column: 1)),
            let kind = TaskEventKind(rawValue: text(statement, column: 3)),
            let actor = TaskMutationActor(rawValue: text(statement, column: 4)),
            let toState = TaskState(rawValue: text(statement, column: 6))
        else {
            throw TaskStoreError.corruptData("invalid task event identity or enum value")
        }
        let fromState: TaskState?
        if let raw = optionalText(statement, column: 5) {
            guard let decoded = TaskState(rawValue: raw) else {
                throw TaskStoreError.corruptData("invalid task event from_state")
            }
            fromState = decoded
        } else {
            fromState = nil
        }
        return TaskEvent(
            id: eventID,
            taskID: TaskID(rawValue: rawTaskID),
            revision: Int(sqlite3_column_int64(statement, 2)),
            kind: kind,
            actor: actor,
            fromState: fromState,
            toState: toState,
            reason: optionalText(statement, column: 7),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
        )
    }

    private func validateRevision(_ record: TaskRecord, expected: Int) throws {
        guard record.revision == expected else {
            throw TaskStoreError.revisionConflict(
                taskID: record.id,
                expected: expected,
                actual: record.revision
            )
        }
    }

    private func prepare(
        _ db: OpaquePointer,
        sql: String,
        statement: inout OpaquePointer?
    ) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TaskStoreError.statementFailed(errorMessage(db))
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer?, index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func bindOptional(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bind(value, to: statement, index: index)
    }

    private func bindOptionalDate(_ value: Date?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
    }

    private func stepDone(_ statement: OpaquePointer?, db: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TaskStoreError.executionFailed(errorMessage(db))
        }
    }

    private func text(_ statement: OpaquePointer?, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private func optionalText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(statement, column: column)
    }

    private func optionalDate(_ statement: OpaquePointer?, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private func errorMessage(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private static func execute(_ db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer
                .map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(db))
            if let errorPointer { sqlite3_free(errorPointer) }
            throw TaskStoreError.executionFailed(message)
        }
    }

    private static func persistenceDate(_ date: Date = Date()) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded(.down)
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private static let taskSelect = """
    SELECT id, title, instruction, state, revision, attempt_count, max_attempts,
           next_eligible_at, last_error, result_summary, origin_conversation_id,
           origin_message_id, created_at, updated_at
    FROM tasks
    """

    private static let schema = """
    CREATE TABLE IF NOT EXISTS tasks (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        instruction TEXT NOT NULL,
        state TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK (revision >= 1),
        attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
        max_attempts INTEGER NOT NULL CHECK (max_attempts >= 1 AND max_attempts <= 10),
        next_eligible_at REAL,
        last_error TEXT,
        result_summary TEXT,
        origin_conversation_id TEXT,
        origin_message_id TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS task_events (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK (revision >= 1),
        kind TEXT NOT NULL,
        actor TEXT NOT NULL,
        from_state TEXT,
        to_state TEXT NOT NULL,
        reason TEXT,
        created_at REAL NOT NULL,
        FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE,
        UNIQUE(task_id, revision)
    );

    CREATE INDEX IF NOT EXISTS idx_tasks_state_updated
        ON tasks(state, updated_at);
    CREATE INDEX IF NOT EXISTS idx_task_events_task_revision
        ON task_events(task_id, revision);
    """
}
