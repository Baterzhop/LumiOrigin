import Foundation
import CSQLite

public actor SQLiteRuntimeTraceStore: RuntimeTraceStoring {
    public let databaseURL: URL
    private var database: OpaquePointer?

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func append(_ trace: RuntimeTrace) throws {
        let db = try openIfNeeded()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(trace)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TraceStoreError.encodingFailed
        }

        let statement = try prepare(
            """
            INSERT INTO runtime_traces(
                id, request_id, conversation_id, created_at, outcome, mode,
                provider, model, model_role, duration_ms, trace_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        try bind(trace.id.uuidString, index: 1, statement: statement, db: db)
        try bind(trace.requestID.uuidString, index: 2, statement: statement, db: db)
        try bind(trace.conversationID.uuidString, index: 3, statement: statement, db: db)
        guard sqlite3_bind_double(statement, 4, trace.createdAt.timeIntervalSince1970) == SQLITE_OK else {
            throw TraceStoreError.sqlite(message(db))
        }
        try bind(trace.outcome.rawValue, index: 5, statement: statement, db: db)
        try bind(trace.mode.rawValue, index: 6, statement: statement, db: db)
        try bind(trace.provider.rawValue, index: 7, statement: statement, db: db)
        try bind(trace.model, index: 8, statement: statement, db: db)
        if let role = trace.modelRole {
            try bind(role.rawValue, index: 9, statement: statement, db: db)
        } else {
            guard sqlite3_bind_null(statement, 9) == SQLITE_OK else {
                throw TraceStoreError.sqlite(message(db))
            }
        }
        guard sqlite3_bind_int64(statement, 10, sqlite3_int64(trace.durationMs)) == SQLITE_OK else {
            throw TraceStoreError.sqlite(message(db))
        }
        try bind(json, index: 11, statement: statement, db: db)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TraceStoreError.sqlite(message(db))
        }
    }

    public func recent(limit: Int) throws -> [RuntimeTrace] {
        let db = try openIfNeeded()
        let statement = try prepare(
            "SELECT trace_json FROM runtime_traces ORDER BY created_at DESC LIMIT ?;",
            db: db
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int(statement, 1, Int32(max(0, limit))) == SQLITE_OK else {
            throw TraceStoreError.sqlite(message(db))
        }

        var traces: [RuntimeTrace] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW,
                  let json = text(statement, 0),
                  let data = json.data(using: .utf8) else {
                throw TraceStoreError.invalidRow
            }
            traces.append(try decode(data))
        }
        return traces
    }

    public func clear() throws {
        let db = try openIfNeeded()
        try exec("DELETE FROM runtime_traces;", db: db)
    }

    private func decode(_ data: Data) throws -> RuntimeTrace {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(RuntimeTrace.self, from: data)
        } catch {
            throw TraceStoreError.decodingFailed(error.localizedDescription)
        }
    }

    private func openIfNeeded() throws -> OpaquePointer {
        if let database { return database }

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let detail = handle.map(message) ?? "SQLite status \(status)"
            if let handle { sqlite3_close(handle) }
            throw TraceStoreError.sqlite("Could not open trace database: \(detail)")
        }

        do {
            try exec("PRAGMA journal_mode = WAL;", db: handle)
            try exec(
                """
                CREATE TABLE IF NOT EXISTS runtime_traces (
                    id TEXT PRIMARY KEY,
                    request_id TEXT NOT NULL,
                    conversation_id TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    outcome TEXT NOT NULL,
                    mode TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    model TEXT NOT NULL,
                    model_role TEXT,
                    duration_ms INTEGER NOT NULL,
                    trace_json TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_runtime_traces_created_at
                    ON runtime_traces(created_at DESC);
                CREATE INDEX IF NOT EXISTS idx_runtime_traces_request_id
                    ON runtime_traces(request_id);
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
            throw TraceStoreError.sqlite(detail)
        }
    }

    private func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw TraceStoreError.sqlite(message(db))
        }
        return statement
    }

    private func bind(_ value: String, index: Int32, statement: OpaquePointer, db: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
        guard status == SQLITE_OK else {
            throw TraceStoreError.sqlite(message(db))
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

public enum TraceStoreError: Error, LocalizedError, Sendable {
    case encodingFailed
    case decodingFailed(String)
    case invalidRow
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Could not encode runtime trace."
        case .decodingFailed(let detail): return "Could not decode runtime trace: \(detail)"
        case .invalidRow: return "Runtime trace row is invalid."
        case .sqlite(let detail): return "Runtime trace SQLite error: \(detail)"
        }
    }
}
