import Foundation
import CSQLite

/// Correctness-first persistent vector index. It stores Float32 embeddings in SQLite and performs
/// exact cosine search. `VectorIndex` is deliberately separate so an ANN/HNSW backend can replace
/// this implementation later without changing retrieval or agent code.
public actor SQLiteVectorIndex: VectorIndex {
    public let databaseURL: URL
    private var database: OpaquePointer?

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public static func defaultIndex() -> SQLiteVectorIndex {
        SQLiteVectorIndex(databaseURL: SQLiteConversationStore.defaultDatabaseURL())
    }

    public func replace(sourceID: String, records: [VectorRecord]) throws {
        let db = try openIfNeeded()
        try exec("BEGIN IMMEDIATE;", db: db, migration: false)

        do {
            try deleteSource(sourceID, db: db)
            for record in records {
                guard record.chunk.sourceID == sourceID else {
                    throw VectorIndexError.writeFailed("Vector record source does not match replacement source.")
                }
                try insert(record, db: db)
            }
            try exec("COMMIT;", db: db, migration: false)
        } catch {
            try? exec("ROLLBACK;", db: db, migration: false)
            throw error
        }
    }

    public func removeSource(id: String) throws {
        let db = try openIfNeeded()
        try deleteSource(id, db: db)
    }

    public func search(vector: [Float], modelID: String, limit: Int) throws -> [KnowledgeHit] {
        try validate(vector)
        let db = try openIfNeeded()
        let statement = try prepare(
            """
            SELECT chunk_id, source_id, title, text, tags_json, source_uri, section, page, vector
            FROM knowledge_vectors
            WHERE model_id = ? AND dimensions = ?;
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        try bind(modelID, index: 1, statement: statement, db: db)
        guard sqlite3_bind_int(statement, 2, Int32(vector.count)) == SQLITE_OK else {
            throw VectorIndexError.statementFailed(message(db))
        }

        var scored: [(KnowledgeHit, Double)] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw VectorIndexError.statementFailed(message(db))
            }

            guard
                let chunkID = text(statement, 0),
                let sourceID = text(statement, 1),
                let title = text(statement, 2),
                let body = text(statement, 3),
                let tagsJSON = text(statement, 4),
                let storedVector = vectorData(statement, 8)
            else { continue }

            let similarity = try VectorMath.cosineSimilarity(vector, storedVector)
            let page: Int?
            if sqlite3_column_type(statement, 7) == SQLITE_NULL {
                page = nil
            } else {
                page = Int(sqlite3_column_int(statement, 7))
            }

            let hit = KnowledgeHit(
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
                score: similarity
            )
            scored.append((hit, similarity))
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.document.id < rhs.0.document.id
                }
                return lhs.1 > rhs.1
            }
            .prefix(max(0, limit))
            .map(\.0)
    }

    private func openIfNeeded() throws -> OpaquePointer {
        if let database { return database }

        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw VectorIndexError.openFailed(error.localizedDescription)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let detail = handle.map(message) ?? "SQLite status \(status)"
            if let handle { sqlite3_close(handle) }
            throw VectorIndexError.openFailed(detail)
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

        CREATE TABLE IF NOT EXISTS knowledge_vectors (
            chunk_id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            model_id TEXT NOT NULL,
            dimensions INTEGER NOT NULL,
            vector BLOB NOT NULL,
            title TEXT NOT NULL,
            text TEXT NOT NULL,
            tags_json TEXT NOT NULL,
            source_uri TEXT,
            section TEXT,
            page INTEGER,
            updated_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_knowledge_vectors_model_dimensions
            ON knowledge_vectors(model_id, dimensions);
        CREATE INDEX IF NOT EXISTS idx_knowledge_vectors_source
            ON knowledge_vectors(source_id);

        INSERT OR IGNORE INTO schema_migrations(version, applied_at)
            VALUES (110, strftime('%s','now'));
        """
        try exec(sql, db: db, migration: true)
    }

    private func insert(_ record: VectorRecord, db: OpaquePointer) throws {
        try validate(record.vector)
        let statement = try prepare(
            """
            INSERT OR REPLACE INTO knowledge_vectors(
                chunk_id, source_id, model_id, dimensions, vector,
                title, text, tags_json, source_uri, section, page, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }

        try bind(record.chunk.id, index: 1, statement: statement, db: db)
        try bind(record.chunk.sourceID, index: 2, statement: statement, db: db)
        try bind(record.modelID, index: 3, statement: statement, db: db)
        guard sqlite3_bind_int(statement, 4, Int32(record.vector.count)) == SQLITE_OK else {
            throw VectorIndexError.writeFailed(message(db))
        }
        try bindVector(record.vector, index: 5, statement: statement, db: db)
        try bind(record.chunk.title, index: 6, statement: statement, db: db)
        try bind(record.chunk.text, index: 7, statement: statement, db: db)
        try bind(encodeTags(record.chunk.tags), index: 8, statement: statement, db: db)
        try bindOptional(record.chunk.sourceURI, index: 9, statement: statement, db: db)
        try bindOptional(record.chunk.section, index: 10, statement: statement, db: db)
        if let page = record.chunk.page {
            guard sqlite3_bind_int(statement, 11, Int32(page)) == SQLITE_OK else {
                throw VectorIndexError.writeFailed(message(db))
            }
        } else if sqlite3_bind_null(statement, 11) != SQLITE_OK {
            throw VectorIndexError.writeFailed(message(db))
        }
        guard
            sqlite3_bind_double(statement, 12, Date().timeIntervalSince1970) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_DONE
        else {
            throw VectorIndexError.writeFailed(message(db))
        }
    }

    private func deleteSource(_ sourceID: String, db: OpaquePointer) throws {
        let statement = try prepare("DELETE FROM knowledge_vectors WHERE source_id = ?;", db: db)
        defer { sqlite3_finalize(statement) }
        try bind(sourceID, index: 1, statement: statement, db: db)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw VectorIndexError.writeFailed(message(db))
        }
    }

    private func validate(_ vector: [Float]) throws {
        guard !vector.isEmpty else { throw VectorIndexError.emptyVector }
        guard vector.allSatisfy({ $0.isFinite }) else { throw VectorIndexError.invalidVector }
    }

    private func encodeVector(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<UInt32>.size)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }

    private func decodeVector(_ data: Data) -> [Float]? {
        guard !data.isEmpty, data.count.isMultiple(of: 4) else { return nil }
        let bytes = [UInt8](data)
        var result: [Float] = []
        result.reserveCapacity(bytes.count / 4)

        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let bits = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            result.append(Float(bitPattern: bits))
        }
        return result
    }

    private func bindVector(_ vector: [Float], index: Int32, statement: OpaquePointer, db: OpaquePointer) throws {
        let data = encodeVector(vector)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
        }
        guard status == SQLITE_OK else {
            throw VectorIndexError.writeFailed(message(db))
        }
    }

    private func vectorData(_ statement: OpaquePointer, _ index: Int32) -> [Float]? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let raw = sqlite3_column_blob(statement, index) else { return nil }
        let data = Data(bytes: raw, count: count)
        return decodeVector(data)
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
            throw VectorIndexError.statementFailed(message(db))
        }
        return statement
    }

    private func bind(_ value: String, index: Int32, statement: OpaquePointer, db: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
        guard status == SQLITE_OK else {
            throw VectorIndexError.writeFailed(message(db))
        }
    }

    private func bindOptional(_ value: String?, index: Int32, statement: OpaquePointer, db: OpaquePointer) throws {
        if let value {
            try bind(value, index: index, statement: statement, db: db)
        } else if sqlite3_bind_null(statement, index) != SQLITE_OK {
            throw VectorIndexError.writeFailed(message(db))
        }
    }

    private func exec(_ sql: String, db: OpaquePointer, migration: Bool) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            if migration {
                throw VectorIndexError.migrationFailed(message(db))
            }
            throw VectorIndexError.writeFailed(message(db))
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
