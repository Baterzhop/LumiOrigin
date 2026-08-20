import Foundation
import CSQLite

public actor SQLiteMemoryRepository: MemoryRepository {
    public let databaseURL: URL
    private var database: OpaquePointer?
    private var lastIssue: String?

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public static func defaultStore() -> SQLiteMemoryRepository {
        SQLiteMemoryRepository(databaseURL: SQLiteConversationStore.defaultDatabaseURL())
    }

    public func upsert(_ record: MemoryRecord) throws {
        guard !record.content.isEmpty else { throw MemoryError.emptyContent }
        let db = try openIfNeeded()
        try exec("BEGIN IMMEDIATE;", db: db, migration: false)

        do {
            let statement = try prepare(
                """
                INSERT OR REPLACE INTO memories(
                    id, kind, content, source_json, confidence, importance,
                    created_at, updated_at, last_used_at, expires_at, is_pinned, tags_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                db: db
            )
            defer { sqlite3_finalize(statement) }

            try bind(record.id.uuidString, index: 1, statement: statement, db: db)
            try bind(record.kind.rawValue, index: 2, statement: statement, db: db)
            try bind(record.content, index: 3, statement: statement, db: db)
            try bind(encode(record.source), index: 4, statement: statement, db: db)
            guard
                sqlite3_bind_double(statement, 5, record.confidence) == SQLITE_OK,
                sqlite3_bind_double(statement, 6, record.importance) == SQLITE_OK,
                sqlite3_bind_double(statement, 7, record.createdAt.timeIntervalSince1970) == SQLITE_OK,
                sqlite3_bind_double(statement, 8, record.updatedAt.timeIntervalSince1970) == SQLITE_OK
            else { throw MemoryError.writeFailed(message(db)) }
            try bindOptionalDate(record.lastUsedAt, index: 9, statement: statement, db: db)
            try bindOptionalDate(record.expiresAt, index: 10, statement: statement, db: db)
            guard sqlite3_bind_int(statement, 11, record.isPinned ? 1 : 0) == SQLITE_OK else {
                throw MemoryError.writeFailed(message(db))
            }
            try bind(encode(record.tags), index: 12, statement: statement, db: db)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw MemoryError.writeFailed(message(db))
            }

            let removeFTS = try prepare("DELETE FROM memory_fts WHERE memory_id = ?;", db: db)
            try bind(record.id.uuidString, index: 1, statement: removeFTS, db: db)
            guard sqlite3_step(removeFTS) == SQLITE_DONE else {
                sqlite3_finalize(removeFTS)
                throw MemoryError.writeFailed(message(db))
            }
            sqlite3_finalize(removeFTS)

            let insertFTS = try prepare(
                "INSERT INTO memory_fts(memory_id, content, tags) VALUES (?, ?, ?);",
                db: db
            )
            defer { sqlite3_finalize(insertFTS) }
            try bind(record.id.uuidString, index: 1, statement: insertFTS, db: db)
            try bind(record.content, index: 2, statement: insertFTS, db: db)
            try bind(record.tags.joined(separator: " "), index: 3, statement: insertFTS, db: db)
            guard sqlite3_step(insertFTS) == SQLITE_DONE else {
                throw MemoryError.writeFailed(message(db))
            }

            try exec("COMMIT;", db: db, migration: false)
            lastIssue = nil
        } catch {
            try? exec("ROLLBACK;", db: db, migration: false)
            lastIssue = error.localizedDescription
            throw error
        }
    }

    public func record(id: UUID) throws -> MemoryRecord? {
        let db = try openIfNeeded()
        let statement = try prepare(
            """
            SELECT id, kind, content, source_json, confidence, importance,
                   created_at, updated_at, last_used_at, expires_at, is_pinned, tags_json
            FROM memories
            WHERE id = ?
            LIMIT 1;
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, index: 1, statement: statement, db: db)

        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else {
            throw MemoryError.statementFailed(message(db))
        }
        return try decodeRecord(statement, db: db)
    }

    public func list(limit: Int = 100) throws -> [MemoryRecord] {
        let db = try openIfNeeded()
        let statement = try prepare(
            """
            SELECT id, kind, content, source_json, confidence, importance,
                   created_at, updated_at, last_used_at, expires_at, is_pinned, tags_json
            FROM memories
            WHERE expires_at IS NULL OR expires_at > ?
            ORDER BY is_pinned DESC, importance DESC, updated_at DESC
            LIMIT ?;
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        guard
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970) == SQLITE_OK,
            sqlite3_bind_int(statement, 2, Int32(max(0, limit))) == SQLITE_OK
        else { throw MemoryError.statementFailed(message(db)) }

        var records: [MemoryRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw MemoryError.statementFailed(message(db)) }
            records.append(try decodeRecord(statement, db: db))
        }
        lastIssue = nil
        return records
    }

    public func search(_ query: String, limit: Int = 8) async -> [MemoryHit] {
        do {
            let db = try openIfNeeded()
            let matchQuery = try ftsQuery(query)
            let candidateLimit = max(8, max(1, limit) * 4)
            let statement = try prepare(
                """
                SELECT m.id, m.kind, m.content, m.source_json, m.confidence, m.importance,
                       m.created_at, m.updated_at, m.last_used_at, m.expires_at, m.is_pinned, m.tags_json
                FROM memory_fts
                JOIN memories m ON m.id = memory_fts.memory_id
                WHERE memory_fts MATCH ?
                  AND (m.expires_at IS NULL OR m.expires_at > ?)
                ORDER BY bm25(memory_fts)
                LIMIT ?;
                """,
                db: db
            )
            defer { sqlite3_finalize(statement) }
            try bind(matchQuery, index: 1, statement: statement, db: db)
            guard
                sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970) == SQLITE_OK,
                sqlite3_bind_int(statement, 3, Int32(candidateLimit)) == SQLITE_OK
            else { throw MemoryError.statementFailed(message(db)) }

            var ranked: [(MemoryRecord, Int)] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw MemoryError.statementFailed(message(db)) }
                ranked.append((try decodeRecord(statement, db: db), ranked.count))
            }

            let hits = ranked.map { record, rank -> MemoryHit in
                let lexical = 1.0 / Double(rank + 1)
                let quality = 0.18 * record.importance + 0.12 * record.confidence
                let pinned = record.isPinned ? 0.15 : 0
                return MemoryHit(record: record, score: lexical + quality + pinned)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.record.updatedAt > rhs.record.updatedAt }
                return lhs.score > rhs.score
            }
            .prefix(max(0, limit))
            .map { $0 }

            lastIssue = nil
            return hits
        } catch MemoryError.invalidQuery {
            lastIssue = nil
            return []
        } catch {
            lastIssue = error.localizedDescription
            return []
        }
    }

    public func delete(id: UUID) throws {
        let db = try openIfNeeded()
        try exec("BEGIN IMMEDIATE;", db: db, migration: false)
        do {
            let fts = try prepare("DELETE FROM memory_fts WHERE memory_id = ?;", db: db)
            try bind(id.uuidString, index: 1, statement: fts, db: db)
            guard sqlite3_step(fts) == SQLITE_DONE else {
                sqlite3_finalize(fts)
                throw MemoryError.writeFailed(message(db))
            }
            sqlite3_finalize(fts)

            let statement = try prepare("DELETE FROM memories WHERE id = ?;", db: db)
            defer { sqlite3_finalize(statement) }
            try bind(id.uuidString, index: 1, statement: statement, db: db)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw MemoryError.writeFailed(message(db))
            }
            try exec("COMMIT;", db: db, migration: false)
            lastIssue = nil
        } catch {
            try? exec("ROLLBACK;", db: db, migration: false)
            lastIssue = error.localizedDescription
            throw error
        }
    }

    public func clearExpired(referenceDate: Date = Date()) throws -> Int {
        let db = try openIfNeeded()
        let idsStatement = try prepare("SELECT id FROM memories WHERE expires_at IS NOT NULL AND expires_at <= ?;", db: db)
        guard sqlite3_bind_double(idsStatement, 1, referenceDate.timeIntervalSince1970) == SQLITE_OK else {
            sqlite3_finalize(idsStatement)
            throw MemoryError.statementFailed(message(db))
        }

        var ids: [String] = []
        while sqlite3_step(idsStatement) == SQLITE_ROW {
            if let id = text(idsStatement, 0) { ids.append(id) }
        }
        sqlite3_finalize(idsStatement)
        guard !ids.isEmpty else { return 0 }

        try exec("BEGIN IMMEDIATE;", db: db, migration: false)
        do {
            for id in ids {
                let fts = try prepare("DELETE FROM memory_fts WHERE memory_id = ?;", db: db)
                try bind(id, index: 1, statement: fts, db: db)
                guard sqlite3_step(fts) == SQLITE_DONE else {
                    sqlite3_finalize(fts)
                    throw MemoryError.writeFailed(message(db))
                }
                sqlite3_finalize(fts)
            }

            let statement = try prepare("DELETE FROM memories WHERE expires_at IS NOT NULL AND expires_at <= ?;", db: db)
            defer { sqlite3_finalize(statement) }
            guard
                sqlite3_bind_double(statement, 1, referenceDate.timeIntervalSince1970) == SQLITE_OK,
                sqlite3_step(statement) == SQLITE_DONE
            else { throw MemoryError.writeFailed(message(db)) }
            try exec("COMMIT;", db: db, migration: false)
            lastIssue = nil
            return ids.count
        } catch {
            try? exec("ROLLBACK;", db: db, migration: false)
            lastIssue = error.localizedDescription
            throw error
        }
    }

    public func markUsed(ids: [UUID], at date: Date = Date()) throws {
        guard !ids.isEmpty else { return }
        let db = try openIfNeeded()
        try exec("BEGIN IMMEDIATE;", db: db, migration: false)
        do {
            for id in ids {
                let statement = try prepare("UPDATE memories SET last_used_at = ? WHERE id = ?;", db: db)
                guard sqlite3_bind_double(statement, 1, date.timeIntervalSince1970) == SQLITE_OK else {
                    sqlite3_finalize(statement)
                    throw MemoryError.writeFailed(message(db))
                }
                try bind(id.uuidString, index: 2, statement: statement, db: db)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    sqlite3_finalize(statement)
                    throw MemoryError.writeFailed(message(db))
                }
                sqlite3_finalize(statement)
            }
            try exec("COMMIT;", db: db, migration: false)
            lastIssue = nil
        } catch {
            try? exec("ROLLBACK;", db: db, migration: false)
            lastIssue = error.localizedDescription
            throw error
        }
    }

    public func issue() -> String? {
        lastIssue
    }

    private func openIfNeeded() throws -> OpaquePointer {
        if let database { return database }

        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw MemoryError.openFailed(error.localizedDescription)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let detail = handle.map(message) ?? "SQLite status \(status)"
            if let handle { sqlite3_close(handle) }
            throw MemoryError.openFailed(detail)
        }

        do {
            try exec("PRAGMA foreign_keys = ON;", db: handle, migration: true)
            try exec("PRAGMA journal_mode = WAL;", db: handle, migration: true)
            try migrate(handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }

        database = handle
        return handle
    }

    private func migrate(_ db: OpaquePointer) throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            content TEXT NOT NULL,
            source_json TEXT NOT NULL,
            confidence REAL NOT NULL,
            importance REAL NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            last_used_at REAL,
            expires_at REAL,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            tags_json TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_memories_kind_importance
            ON memories(kind, importance DESC, updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_memories_expiration
            ON memories(expires_at);

        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
            memory_id UNINDEXED,
            content,
            tags,
            tokenize = 'unicode61'
        );

        INSERT OR IGNORE INTO schema_migrations(version, applied_at)
            VALUES (200, strftime('%s','now'));
        """
        try exec(sql, db: db, migration: true)
    }

    private func decodeRecord(_ statement: OpaquePointer, db: OpaquePointer) throws -> MemoryRecord {
        guard
            let idRaw = text(statement, 0),
            let id = UUID(uuidString: idRaw),
            let kindRaw = text(statement, 1),
            let kind = MemoryKind(rawValue: kindRaw),
            let content = text(statement, 2),
            let sourceJSON = text(statement, 3),
            let tagsJSON = text(statement, 11)
        else { throw MemoryError.statementFailed("Memory row is incomplete.") }

        return MemoryRecord(
            id: id,
            kind: kind,
            content: content,
            source: decode(MemorySource.self, from: sourceJSON) ?? MemorySource(kind: .system),
            confidence: sqlite3_column_double(statement, 4),
            importance: sqlite3_column_double(statement, 5),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            lastUsedAt: optionalDate(statement, 8),
            expiresAt: optionalDate(statement, 9),
            isPinned: sqlite3_column_int(statement, 10) != 0,
            tags: decode([String].self, from: tagsJSON) ?? []
        )
    }

    private func ftsQuery(_ query: String) throws -> String {
        let tokens = query
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 }

        guard !tokens.isEmpty else { throw MemoryError.invalidQuery }
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        guard
            let data = try? JSONEncoder().encode(value),
            let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    private func decode<T: Decodable>(_ type: T.Type, from string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MemoryError.statementFailed(message(db))
        }
        return statement
    }

    private func bind(_ value: String, index: Int32, statement: OpaquePointer, db: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
        guard status == SQLITE_OK else { throw MemoryError.writeFailed(message(db)) }
    }

    private func bindOptionalDate(_ value: Date?, index: Int32, statement: OpaquePointer, db: OpaquePointer) throws {
        if let value {
            guard sqlite3_bind_double(statement, index, value.timeIntervalSince1970) == SQLITE_OK else {
                throw MemoryError.writeFailed(message(db))
            }
        } else if sqlite3_bind_null(statement, index) != SQLITE_OK {
            throw MemoryError.writeFailed(message(db))
        }
    }

    private func optionalDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func exec(_ sql: String, db: OpaquePointer, migration: Bool) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            if migration { throw MemoryError.migrationFailed(message(db)) }
            throw MemoryError.writeFailed(message(db))
        }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        let chars = UnsafeRawPointer(raw).assumingMemoryBound(to: CChar.self)
        return String(cString: chars)
    }

    private func message(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
