import Foundation
import CSQLite

public actor SQLiteToolAuditStore: ToolAuditStoring {
    public let databaseURL: URL
    private var database: OpaquePointer?

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func append(_ event: ToolAuditEvent) throws {
        let db = try openIfNeeded()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(event)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ToolRuntimeError.executionFailed("Could not encode tool audit event.")
        }

        let statement = try prepare(
            "INSERT INTO tool_audit_events(id, started_at, finished_at, event_json) VALUES (?, ?, ?, ?);",
            db: db
        )
        defer { sqlite3_finalize(statement) }

        try bind(event.id.uuidString, index: 1, statement: statement, db: db)
        guard sqlite3_bind_double(statement, 2, event.startedAt.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_double(statement, 3, event.finishedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw ToolRuntimeError.executionFailed("Could not bind tool audit timestamps.")
        }
        try bind(json, index: 4, statement: statement, db: db)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ToolRuntimeError.executionFailed("Could not persist tool audit event: \(message(db))")
        }
    }

    public func recent(limit: Int) throws -> [ToolAuditEvent] {
        let db = try openIfNeeded()
        let statement = try prepare(
            "SELECT event_json FROM tool_audit_events ORDER BY finished_at DESC LIMIT ?;",
            db: db
        )
        defer { sqlite3_finalize(statement) }

        guard sqlite3_bind_int(statement, 1, Int32(max(0, limit))) == SQLITE_OK else {
            throw ToolRuntimeError.executionFailed("Could not bind tool audit limit.")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var events: [ToolAuditEvent] = []

        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw ToolRuntimeError.executionFailed("Could not read tool audit events: \(message(db))")
            }
            guard let json = text(statement, 0), let data = json.data(using: .utf8) else { continue }
            do {
                events.append(try decoder.decode(ToolAuditEvent.self, from: data))
            } catch {
                throw ToolRuntimeError.executionFailed("Could not decode persisted tool audit event: \(error.localizedDescription)")
            }
        }

        return events
    }

    private func openIfNeeded() throws -> OpaquePointer {
        if let database { return database }

        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ToolRuntimeError.executionFailed("Could not create tool audit database directory: \(error.localizedDescription)")
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let detail = handle.map(message) ?? "SQLite status \(status)"
            if let handle { sqlite3_close(handle) }
            throw ToolRuntimeError.executionFailed("Could not open tool audit database: \(detail)")
        }

        do {
            try exec("PRAGMA journal_mode = WAL;", db: handle)
            try exec(
                """
                CREATE TABLE IF NOT EXISTS tool_audit_events (
                    id TEXT PRIMARY KEY,
                    started_at REAL NOT NULL,
                    finished_at REAL NOT NULL,
                    event_json TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_tool_audit_finished_at
                    ON tool_audit_events(finished_at DESC);
                """,
                db: handle
            )
        } catch {
            sqlite3_close(handle)
            throw error
        }

        database = handle
        return handle
    }

    private func exec(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let detail = errorMessage.map { String(cString: $0) } ?? message(db)
            sqlite3_free(errorMessage)
            throw ToolRuntimeError.executionFailed("Tool audit database migration failed: \(detail)")
        }
    }

    private func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ToolRuntimeError.executionFailed("Tool audit statement failed: \(message(db))")
        }
        return statement
    }

    private func bind(_ value: String, index: Int32, statement: OpaquePointer, db: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
        guard status == SQLITE_OK else {
            throw ToolRuntimeError.executionFailed("Tool audit bind failed: \(message(db))")
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private func message(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
