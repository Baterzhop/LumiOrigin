import Foundation
import CSQLite

private final class MemorySQLiteConnection: @unchecked Sendable {
    let raw: OpaquePointer

    init(raw: OpaquePointer) {
        self.raw = raw
    }

    deinit {
        sqlite3_close_v2(raw)
    }
}

/// Durable long-term user-memory storage with append-only revisions for active
/// facts. Replacements use optimistic revision matching and are transactional.
/// `forget` intentionally hard-deletes the logical memory and its revisions so
/// a user-requested deletion is not retained as hidden personal content.
public actor SQLiteMemoryStore: MemoryStore {
    private let connection: MemorySQLiteConnection

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
            throw MemoryStoreError.openFailed(message)
        }

        do {
            try Self.execute(rawHandle, sql: "PRAGMA foreign_keys = ON;")
            try Self.execute(rawHandle, sql: "PRAGMA journal_mode = WAL;")
            try Self.execute(rawHandle, sql: "PRAGMA synchronous = NORMAL;")
            try Self.execute(rawHandle, sql: Self.schema)
            connection = MemorySQLiteConnection(raw: rawHandle)
        } catch {
            sqlite3_close_v2(rawHandle)
            throw error
        }
    }

    public func load(key: String) async throws -> UserMemoryRecord? {
        let canonical = try Self.validateCanonicalKey(key)
        return try fetchCurrent(db: connection.raw, whereSQL: "r.canonical_key = ?1") { statement in
            bind(canonical, to: statement, index: 1)
        }
    }

    public func load(id: UUID) async throws -> UserMemoryRecord? {
        try fetchCurrent(db: connection.raw, whereSQL: "r.id = ?1") { statement in
            bind(id.uuidString, to: statement, index: 1)
        }
    }

    public func listActive() async throws -> [UserMemoryRecord] {
        let db = connection.raw
        let sql = Self.currentRecordSelect + " ORDER BY r.updated_at DESC, r.canonical_key ASC;"
        var statement: OpaquePointer?
        try prepare(db, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        var records: [UserMemoryRecord] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                records.append(try decodeRecord(statement))
            case SQLITE_DONE:
                return records
            default:
                throw MemoryStoreError.executionFailed(errorMessage(db))
            }
        }
    }

    public func history(memoryID: UUID) async throws -> [MemoryRevision] {
        let db = connection.raw
        let sql = """
        SELECT id, memory_id, revision_index, kind, value, confidence,
               provenance_json, created_at
        FROM memory_revisions
        WHERE memory_id = ?1
        ORDER BY revision_index ASC;
        """

        var statement: OpaquePointer?
        try prepare(db, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bind(memoryID.uuidString, to: statement, index: 1)

        var revisions: [MemoryRevision] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                revisions.append(try decodeRevision(statement, offset: 0))
            case SQLITE_DONE:
                return revisions
            default:
                throw MemoryStoreError.executionFailed(errorMessage(db))
            }
        }
    }

    public func upsert(_ request: MemoryWriteRequest) async throws -> MemoryWriteResult {
        let canonical = try Self.validateCanonicalKey(request.key)
        let value = try MemoryService.validatedValue(request.value)
        try MemoryService.validateConfidence(request.confidence)
        let provenanceJSON = try encodeProvenance(request.provenance)
        let db = connection.raw
        let now = Self.persistenceDate()

        try Self.execute(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            let existing = try fetchCurrent(
                db: db,
                whereSQL: "r.canonical_key = ?1"
            ) { statement in
                bind(canonical, to: statement, index: 1)
            }

            let memoryID: UUID
            let recordCreatedAt: Date
            let nextRevision: Int
            let previousRevision: MemoryRevision?

            if let existing {
                guard request.expectedRevision == existing.revision else {
                    throw MemoryStoreError.revisionConflict(
                        key: canonical,
                        expected: request.expectedRevision,
                        actual: existing.revision
                    )
                }
                memoryID = existing.id
                recordCreatedAt = existing.createdAt
                nextRevision = existing.revision + 1
                previousRevision = existing.currentRevision
            } else {
                guard request.expectedRevision == nil else {
                    throw MemoryStoreError.revisionConflict(
                        key: canonical,
                        expected: request.expectedRevision,
                        actual: nil
                    )
                }
                memoryID = UUID()
                recordCreatedAt = now
                nextRevision = 1
                previousRevision = nil
            }

            let revision = MemoryRevision(
                id: UUID(),
                memoryID: memoryID,
                revision: nextRevision,
                kind: request.kind,
                value: value,
                confidence: request.confidence,
                provenance: request.provenance,
                createdAt: now
            )

            if existing == nil {
                var statement: OpaquePointer?
                try prepare(
                    db,
                    sql: """
                    INSERT INTO memory_records (
                        id, canonical_key, active_revision_id, created_at, updated_at
                    ) VALUES (?1, ?2, ?3, ?4, ?5);
                    """,
                    statement: &statement
                )
                defer { sqlite3_finalize(statement) }
                bind(memoryID.uuidString, to: statement, index: 1)
                bind(canonical, to: statement, index: 2)
                bind(revision.id.uuidString, to: statement, index: 3)
                sqlite3_bind_double(statement, 4, recordCreatedAt.timeIntervalSince1970)
                sqlite3_bind_double(statement, 5, now.timeIntervalSince1970)
                try stepDone(statement, db: db)
            }

            do {
                var statement: OpaquePointer?
                try prepare(
                    db,
                    sql: """
                    INSERT INTO memory_revisions (
                        id, memory_id, revision_index, kind, value, confidence,
                        provenance_json, created_at
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
                    """,
                    statement: &statement
                )
                defer { sqlite3_finalize(statement) }
                bind(revision.id.uuidString, to: statement, index: 1)
                bind(memoryID.uuidString, to: statement, index: 2)
                sqlite3_bind_int64(statement, 3, sqlite3_int64(nextRevision))
                bind(request.kind.rawValue, to: statement, index: 4)
                bind(value, to: statement, index: 5)
                sqlite3_bind_double(statement, 6, request.confidence)
                bind(provenanceJSON, to: statement, index: 7)
                sqlite3_bind_double(statement, 8, now.timeIntervalSince1970)
                try stepDone(statement, db: db)
            }

            if existing != nil {
                var statement: OpaquePointer?
                try prepare(
                    db,
                    sql: """
                    UPDATE memory_records
                    SET active_revision_id = ?1, updated_at = ?2
                    WHERE id = ?3;
                    """,
                    statement: &statement
                )
                defer { sqlite3_finalize(statement) }
                bind(revision.id.uuidString, to: statement, index: 1)
                sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
                bind(memoryID.uuidString, to: statement, index: 3)
                try stepDone(statement, db: db)
            }

            try Self.execute(db, sql: "COMMIT;")

            return MemoryWriteResult(
                record: UserMemoryRecord(
                    id: memoryID,
                    key: canonical,
                    currentRevision: revision,
                    createdAt: recordCreatedAt,
                    updatedAt: now
                ),
                previousRevision: previousRevision
            )
        } catch {
            try? Self.execute(db, sql: "ROLLBACK;")
            throw error
        }
    }

    public func forget(key: String, expectedRevision: Int?) async throws -> UserMemoryRecord? {
        let canonical = try Self.validateCanonicalKey(key)
        let db = connection.raw

        try Self.execute(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            let existing = try fetchCurrent(
                db: db,
                whereSQL: "r.canonical_key = ?1"
            ) { statement in
                bind(canonical, to: statement, index: 1)
            }

            guard let existing else {
                if expectedRevision != nil {
                    throw MemoryStoreError.revisionConflict(
                        key: canonical,
                        expected: expectedRevision,
                        actual: nil
                    )
                }
                try Self.execute(db, sql: "COMMIT;")
                return nil
            }

            guard expectedRevision == existing.revision else {
                throw MemoryStoreError.revisionConflict(
                    key: canonical,
                    expected: expectedRevision,
                    actual: existing.revision
                )
            }

            var statement: OpaquePointer?
            try prepare(
                db,
                sql: "DELETE FROM memory_records WHERE id = ?1;",
                statement: &statement
            )
            defer { sqlite3_finalize(statement) }
            bind(existing.id.uuidString, to: statement, index: 1)
            try stepDone(statement, db: db)

            try Self.execute(db, sql: "COMMIT;")
            return existing
        } catch {
            try? Self.execute(db, sql: "ROLLBACK;")
            throw error
        }
    }

    private func fetchCurrent(
        db: OpaquePointer,
        whereSQL: String,
        bindValues: (OpaquePointer?) -> Void
    ) throws -> UserMemoryRecord? {
        let sql = Self.currentRecordSelect + " WHERE \(whereSQL) LIMIT 1;"
        var statement: OpaquePointer?
        try prepare(db, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bindValues(statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeRecord(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw MemoryStoreError.executionFailed(errorMessage(db))
        }
    }

    private func decodeRecord(_ statement: OpaquePointer?) throws -> UserMemoryRecord {
        guard let memoryID = UUID(uuidString: text(statement, column: 0)) else {
            throw MemoryStoreError.corruptData("invalid memory UUID")
        }

        let revision = try decodeRevision(statement, offset: 4)
        guard revision.memoryID == memoryID else {
            throw MemoryStoreError.corruptData("active revision memory identity mismatch")
        }

        return UserMemoryRecord(
            id: memoryID,
            key: text(statement, column: 1),
            currentRevision: revision,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        )
    }

    private func decodeRevision(
        _ statement: OpaquePointer?,
        offset: Int32
    ) throws -> MemoryRevision {
        guard
            let revisionID = UUID(uuidString: text(statement, column: offset)),
            let memoryID = UUID(uuidString: text(statement, column: offset + 1)),
            let kind = MemoryKind(rawValue: text(statement, column: offset + 3))
        else {
            throw MemoryStoreError.corruptData("invalid memory revision identity or kind")
        }

        let provenanceText = text(statement, column: offset + 6)
        guard let provenanceData = provenanceText.data(using: .utf8) else {
            throw MemoryStoreError.corruptData("memory provenance is not UTF-8")
        }

        let provenance: MemoryProvenance
        do {
            provenance = try JSONDecoder().decode(MemoryProvenance.self, from: provenanceData)
        } catch {
            throw MemoryStoreError.corruptData("invalid memory provenance JSON")
        }

        return MemoryRevision(
            id: revisionID,
            memoryID: memoryID,
            revision: Int(sqlite3_column_int64(statement, offset + 2)),
            kind: kind,
            value: text(statement, column: offset + 4),
            confidence: sqlite3_column_double(statement, offset + 5),
            provenance: provenance,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 7))
        )
    }

    private func encodeProvenance(_ provenance: MemoryProvenance) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(provenance)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MemoryStoreError.executionFailed("memory provenance could not be encoded")
        }
        return string
    }

    private static func validateCanonicalKey(_ key: String) throws -> String {
        let validated = try MemoryService.validatedKey(key)
        guard validated == key else {
            throw MemoryStoreError.invalidKey
        }
        return validated
    }

    private func prepare(
        _ db: OpaquePointer,
        sql: String,
        statement: inout OpaquePointer?
    ) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MemoryStoreError.statementFailed(errorMessage(db))
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer?, index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func stepDone(_ statement: OpaquePointer?, db: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MemoryStoreError.executionFailed(errorMessage(db))
        }
    }

    private func text(_ statement: OpaquePointer?, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
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
            throw MemoryStoreError.executionFailed(message)
        }
    }

    private static func persistenceDate(_ date: Date = Date()) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded(.down)
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private static let currentRecordSelect = """
    SELECT r.id, r.canonical_key, r.created_at, r.updated_at,
           v.id, v.memory_id, v.revision_index, v.kind, v.value,
           v.confidence, v.provenance_json, v.created_at
    FROM memory_records r
    JOIN memory_revisions v ON v.id = r.active_revision_id
    """

    private static let schema = """
    CREATE TABLE IF NOT EXISTS memory_records (
        id TEXT PRIMARY KEY,
        canonical_key TEXT NOT NULL UNIQUE,
        active_revision_id TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS memory_revisions (
        id TEXT PRIMARY KEY,
        memory_id TEXT NOT NULL,
        revision_index INTEGER NOT NULL CHECK(revision_index > 0),
        kind TEXT NOT NULL,
        value TEXT NOT NULL,
        confidence REAL NOT NULL CHECK(confidence >= 0.0 AND confidence <= 1.0),
        provenance_json TEXT NOT NULL,
        created_at REAL NOT NULL,
        FOREIGN KEY(memory_id) REFERENCES memory_records(id) ON DELETE CASCADE,
        UNIQUE(memory_id, revision_index)
    );

    CREATE INDEX IF NOT EXISTS idx_memory_records_updated
        ON memory_records(updated_at DESC, canonical_key ASC);

    CREATE INDEX IF NOT EXISTS idx_memory_revisions_history
        ON memory_revisions(memory_id, revision_index ASC);
    """
}
