import Foundation
import CSQLite

public actor SQLiteAgentRunStore: AgentRunStoring {
    public let databaseURL: URL
    private var database: OpaquePointer?

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func save(_ run: AgentRun) throws {
        let db = try openIfNeeded()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(run)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AgentRuntimeError.persistenceFailed("Could not encode agent run.")
        }

        let statement = try prepare(
            """
            INSERT INTO agent_runs(id, state, created_at, updated_at, run_json)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                state = excluded.state,
                updated_at = excluded.updated_at,
                run_json = excluded.run_json;
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        try bind(run.id.uuidString, index: 1, statement: statement, db: db)
        try bind(run.state.rawValue, index: 2, statement: statement, db: db)
        guard sqlite3_bind_double(statement, 3, run.createdAt.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_double(statement, 4, run.updatedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw AgentRuntimeError.persistenceFailed("Could not bind agent run timestamps.")
        }
        try bind(json, index: 5, statement: statement, db: db)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AgentRuntimeError.persistenceFailed(message(db))
        }
    }

    public func load(id: UUID) throws -> AgentRun? {
        let db = try openIfNeeded()
        let statement = try prepare(
            "SELECT run_json FROM agent_runs WHERE id = ? LIMIT 1;",
            db: db
        )
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, index: 1, statement: statement, db: db)

        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let json = text(statement, 0), let data = json.data(using: .utf8) else {
            throw AgentRuntimeError.persistenceFailed("Agent run row is invalid.")
        }
        return try decode(data)
    }

    public func recent(limit: Int) throws -> [AgentRun] {
        let db = try openIfNeeded()
        let statement = try prepare(
            "SELECT run_json FROM agent_runs ORDER BY updated_at DESC LIMIT ?;",
            db: db
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int(statement, 1, Int32(max(0, limit))) == SQLITE_OK else {
            throw AgentRuntimeError.persistenceFailed("Could not bind agent run limit.")
        }

        var runs: [AgentRun] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let json = text(statement, 0), let data = json.data(using: .utf8) else {
                throw AgentRuntimeError.persistenceFailed("Agent run row is invalid.")
            }
            runs.append(try decode(data))
        }
        return runs
    }

    private func decode(_ data: Data) throws -> AgentRun {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(AgentRun.self, from: data)
        } catch {
            throw AgentRuntimeError.persistenceFailed("Could not decode agent run: \(error.localizedDescription)")
        }
    }

    private func openIfNeeded() throws -> OpaquePointer {
        if let database { return database }

        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw AgentRuntimeError.persistenceFailed("Could not create agent database directory: \(error.localizedDescription)")
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let detail = handle.map(message) ?? "SQLite status \(status)"
            if let handle { sqlite3_close(handle) }
            throw AgentRuntimeError.persistenceFailed("Could not open agent database: \(detail)")
        }

        do {
            try exec("PRAGMA journal_mode = WAL;", db: handle)
            try exec(
                """
                CREATE TABLE IF NOT EXISTS agent_runs (
                    id TEXT PRIMARY KEY,
                    state TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    run_json TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_agent_runs_updated_at
                    ON agent_runs(updated_at DESC);
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
            throw AgentRuntimeError.persistenceFailed(detail)
        }
    }

    private func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AgentRuntimeError.persistenceFailed(message(db))
        }
        return statement
    }

    private func bind(_ value: String, index: Int32, statement: OpaquePointer, db: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
        guard status == SQLITE_OK else {
            throw AgentRuntimeError.persistenceFailed(message(db))
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
