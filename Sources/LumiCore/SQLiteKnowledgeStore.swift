import Foundation
import CSQLite

public enum KnowledgeStoreError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case migrationFailed(String)
    case statementFailed(String)
    case writeFailed(String)
    case invalidQuery

    public var errorDescription: String? {
        switch self {
        case .openFailed(let detail): return "Could not open the knowledge database: \(detail)"
        case .migrationFailed(let detail): return "Could not migrate the knowledge database: \(detail)"
        case .statementFailed(let detail): return "Knowledge database statement failed: \(detail)"
        case .writeFailed(let detail): return "Could not write knowledge data: \(detail)"
        case .invalidQuery: return "The knowledge search query contains no searchable terms."
        }
    }
}

public actor SQLiteKnowledgeStore: KnowledgeStore {
    public let databaseURL: URL
    private var database: OpaquePointer?
    private var lastIssue: String?

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public static func defaultStore() -> SQLiteKnowledgeStore {
        SQLiteKnowledgeStore(databaseURL: SQLiteConversationStore.defaultDatabaseURL())
    }

    public func replace(source: KnowledgeSourceRecord, chunks: [KnowledgeChunkRecord]) throws {
        let db = try openIfNeeded()
        try exec("BEGIN IMMEDIATE;", db: db, migration: false)

        do {
            try deleteIndexedChunks(sourceID: source.id, db: db)
            try upsertSource(source, db: db)

            for chunk in chunks {
                try insertChunk(chunk, db: db)
                try insertFTS(chunk, db: db)
            }

            try exec("COMMIT;", db: db, migration: false)
            lastIssue = nil
        } catch {
            try? exec("ROLLBACK;", db: db, migration: false)
            lastIssue = error.localizedDescription
            throw error
        }
    }

    public func source(id: String) throws -> KnowledgeSourceRecord? {
        let db = try openIfNeeded()
        let statement = try prepare(
            "SELECT id, title, source_type, source_uri, tags_json, content_hash, created_at, updated_at FROM knowledge_sources WHERE id = ? LIMIT 1;",
            db: db
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, index: 1, statement: statement, db: db)

        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else {
            throw KnowledgeStoreError.statementFailed(message(db))
        }

        guard
            let sourceID = text(statement, 0),
            let title = text(statement, 1),
            let typeRaw = text(statement, 2),
            let sourceType = KnowledgeSourceType(rawValue: typeRaw),
            let tagsJSON = text(statement, 4),
            let contentHash = text(statement, 5)
        else {
            throw KnowledgeStoreError.statementFailed("Knowledge source row is incomplete.")
        }

        return KnowledgeSourceRecord(
            id: sourceID,
            title: title,
            sourceType: sourceType,
            sourceURI: text(statement, 3),
            tags: decodeTags(tagsJSON),
            contentHash: contentHash,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        )
    }

    public func removeSource(id: String) throws {
        let db = try openIfNeeded()
        try exec("BEGIN IMMEDIATE;", db: db, migration: false)

        do {
            try deleteIndexedChunks(sourceID: id, db: db)

            let statement = try prepare("DELETE FROM knowledge_sources WHERE id = ?;", db: db)
            defer { sqlite3_finalize(statement) }
            try bind(id, index: 1, statement: statement, db: db)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw KnowledgeStoreError.writeFailed(message(db))
            }

            try exec("COMMIT;", db: db, migration: false)
            lastIssue = nil
        } catch {
            try? exec("ROLLBACK;", db: db, migration: false)
            lastIssue = error.localizedDescription
            throw error
        }
    }

    public func search(_ query: String, limit: Int = 8) async -> [KnowledgeHit] {
        do {
            let db = try openIfNeeded()
            let matchQuery = try ftsQuery(query)
            let statement = try prepare(
                """
                SELECT
                    c.id,
                    c.source_id,
                    c.title,
                    c.text,
                    c.tags_json,
                    c.source_uri,
                    c.section,
                    c.page
                FROM knowledge_fts
                JOIN knowledge_chunks c ON c.id = knowledge_fts.chunk_id
                WHERE knowledge_fts MATCH ?
                ORDER BY bm25(knowledge_fts)
                LIMIT ?;
                """,
                db: db
            )
            defer { sqlite3_finalize(statement) }

            try bind(matchQuery, index: 1, statement: statement, db: db)
            guard sqlite3_bind_int(statement, 2, Int32(max(1, limit))) == SQLITE_OK else {
                throw KnowledgeStoreError.statementFailed(message(db))
            }

            var hits: [KnowledgeHit] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    throw KnowledgeStoreError.statementFailed(message(db))
                }

                guard
                    let chunkID = text(statement, 0),
                    let sourceID = text(statement, 1),
                    let title = text(statement, 2),
                    let body = text(statement, 3),
                    let tagsJSON = text(statement, 4)
                else { continue }

                let page: Int?
                if sqlite3_column_type(statement, 7) == SQLITE_NULL {
                    page = nil
                } else {
                    page = Int(sqlite3_column_int(statement, 7))
                }

                let rank = hits.count
                hits.append(
                    KnowledgeHit(
                        document: KnowledgeDocument(
                            id: chunkID,
                            title: title,
                            text: body,
                            tags: decodeTags(tagsJSON),
                            sourceID: sourceID,
                            chunkID: chunkID,
                            sourceURI: text(statement, 5),
                            section: text(statement, 6),
                            page: page
                        ),
                        // FTS5 bm25 ordering is preserved by SQL. A reciprocal-rank score keeps
                        // the existing higher-is-better `KnowledgeHit` contract until rank fusion arrives.
                        score: 1.0 / Double(rank + 1)
                    )
                )
            }

            lastIssue = nil
            return hits
        } catch KnowledgeStoreError.invalidQuery {
            lastIssue = nil
            return []
        } catch {
            lastIssue = error.localizedDescription
            return []
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
            throw KnowledgeStoreError.openFailed(error.localizedDescription)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let detail = handle.map(message) ?? "SQLite status \(status)"
            if let handle { sqlite3_close(handle) }
            throw KnowledgeStoreError.openFailed(detail)
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

        CREATE TABLE IF NOT EXISTS knowledge_sources (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            source_type TEXT NOT NULL,
            source_uri TEXT,
            tags_json TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS knowledge_chunks (
            id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            title TEXT NOT NULL,
            text TEXT NOT NULL,
            tags_json TEXT NOT NULL,
            source_uri TEXT,
            section TEXT,
            page INTEGER,
            content_hash TEXT NOT NULL,
            FOREIGN KEY(source_id) REFERENCES knowledge_sources(id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_source_ordinal
            ON knowledge_chunks(source_id, ordinal);

        CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(
            chunk_id UNINDEXED,
            source_id UNINDEXED,
            title,
            text,
            tags,
            tokenize = 'unicode61'
        );

        INSERT OR IGNORE INTO schema_migrations(version, applied_at)
            VALUES (100, strftime('%s','now'));
        """
        try exec(sql, db: db, migration: true)
    }

    private func upsertSource(_ source: KnowledgeSourceRecord, db: OpaquePointer) throws {
        let statement = try prepare(
            """
            INSERT OR REPLACE INTO knowledge_sources(
                id, title, source_type, source_uri, tags_json, content_hash, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        try bind(source.id, index: 1, statement: statement, db: db)
        try bind(source.title, index: 2, statement: statement, db: db)
        try bind(source.sourceType.rawValue, index: 3, statement: statement, db: db)
        try bindOptional(source.sourceURI, index: 4, statement: statement, db: db)
        try bind(encodeTags(source.tags), index: 5, statement: statement, db: db)
        try bind(source.contentHash, index: 6, statement: statement, db: db)
        guard
            sqlite3_bind_double(statement, 7, source.createdAt.timeIntervalSince1970) == SQLITE_OK,
            sqlite3_bind_double(statement, 8, source.updatedAt.timeIntervalSince1970) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_DONE
        else {
            throw KnowledgeStoreError.writeFailed(message(db))
        }
    }

    private func insertChunk(_ chunk: KnowledgeChunkRecord, db: OpaquePointer) throws {
        let statement = try prepare(
            """
            INSERT INTO knowledge_chunks(
                id, source_id, ordinal, title, text, tags_json, source_uri, section, page, content_hash
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        try bind(chunk.id, index: 1, statement: statement, db: db)
        try bind(chunk.sourceID, index: 2, statement: statement, db: db)
        guard sqlite3_bind_int(statement, 3, Int32(chunk.ordinal)) == SQLITE_OK else {
            throw KnowledgeStoreError.writeFailed(message(db))
        }
        try bind(chunk.title, index: 4, statement: statement, db: db)
        try bind(chunk.text, index: 5, statement: statement, db: db)
        try bind(encodeTags(chunk.tags), index: 6, statement: statement, db: db)
        try bindOptional(chunk.sourceURI, index: 7, statement: statement, db: db)
        try bindOptional(chunk.section, index: 8, statement: statement, db: db)
        if let page = chunk.page {
            guard sqlite3_bind_int(statement, 9, Int32(page)) == SQLITE_OK else {
                throw KnowledgeStoreError.writeFailed(message(db))
            }
        } else {
            guard sqlite3_bind_null(statement, 9) == SQLITE_OK else {
                throw KnowledgeStoreError.writeFailed(message(db))
            }
        }
        try bind(chunk.contentHash, index: 10, statement: statement, db: db)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw KnowledgeStoreError.writeFailed(message(db))
        }
    }

    private func insertFTS(_ chunk: KnowledgeChunkRecord, db: OpaquePointer) throws {
        let statement = try prepare(
            "INSERT INTO knowledge_fts(chunk_id, source_id, title, text, tags) VALUES (?, ?, ?, ?, ?);",
            db: db
        )
        defer { sqlite3_finalize(statement) }

        try bind(chunk.id, index: 1, statement: statement, db: db)
        try bind(chunk.sourceID, index: 2, statement: statement, db: db)
        try bind(chunk.title, index: 3, statement: statement, db: db)
        try bind(chunk.text, index: 4, statement: statement, db: db)
        try bind(chunk.tags.joined(separator: " "), index: 5, statement: statement, db: db)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw KnowledgeStoreError.writeFailed(message(db))
        }
    }

    private func deleteIndexedChunks(sourceID: String, db: OpaquePointer) throws {
        let fts = try prepare("DELETE FROM knowledge_fts WHERE source_id = ?;", db: db)
        try bind(sourceID, index: 1, statement: fts, db: db)
        guard sqlite3_step(fts) == SQLITE_DONE else {
            sqlite3_finalize(fts)
            throw KnowledgeStoreError.writeFailed(message(db))
        }
        sqlite3_finalize(fts)

        let chunks = try prepare("DELETE FROM knowledge_chunks WHERE source_id = ?;", db: db)
        defer { sqlite3_finalize(chunks) }
        try bind(sourceID, index: 1, statement: chunks, db: db)
        guard sqlite3_step(chunks) == SQLITE_DONE else {
            throw KnowledgeStoreError.writeFailed(message(db))
        }
    }

    private func ftsQuery(_ query: String) throws -> String {
        let tokens = query
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 }

        guard !tokens.isEmpty else { throw KnowledgeStoreError.invalidQuery }
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
    }

    private func encodeTags(_ tags: [String]) -> String {
        guard let data = try? JSONEncoder().encode(tags),
              let string = String(data: data, encoding: .utf8)
        else { return "[]" }
        return string
    }

    private func decodeTags(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8),
              let tags = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return tags
    }

    private func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw KnowledgeStoreError.statementFailed(message(db))
        }
        return statement
    }

    private func bind(_ value: String, index: Int32, statement: OpaquePointer, db: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
        guard status == SQLITE_OK else {
            throw KnowledgeStoreError.writeFailed(message(db))
        }
    }

    private func bindOptional(_ value: String?, index: Int32, statement: OpaquePointer, db: OpaquePointer) throws {
        if let value {
            try bind(value, index: index, statement: statement, db: db)
        } else if sqlite3_bind_null(statement, index) != SQLITE_OK {
            throw KnowledgeStoreError.writeFailed(message(db))
        }
    }

    private func exec(_ sql: String, db: OpaquePointer, migration: Bool) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            if migration {
                throw KnowledgeStoreError.migrationFailed(message(db))
            }
            throw KnowledgeStoreError.writeFailed(message(db))
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
