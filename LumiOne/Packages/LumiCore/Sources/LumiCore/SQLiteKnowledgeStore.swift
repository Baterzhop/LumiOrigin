import Foundation
import CSQLite

public enum KnowledgeStoreError: Error, CustomStringConvertible, Sendable, Equatable {
    case openFailed(String)
    case statementFailed(String)
    case executionFailed(String)
    case invalidRecord(String)
    case corruptData(String)

    public var description: String {
        switch self {
        case .openFailed(let message):
            return "Knowledge SQLite open failed: \(message)"
        case .statementFailed(let message):
            return "Knowledge SQLite statement failed: \(message)"
        case .executionFailed(let message):
            return "Knowledge SQLite execution failed: \(message)"
        case .invalidRecord(let message):
            return "Knowledge record is invalid: \(message)"
        case .corruptData(let message):
            return "Knowledge SQLite data is invalid: \(message)"
        }
    }
}

private final class KnowledgeSQLiteConnection: @unchecked Sendable {
    let raw: OpaquePointer

    init(raw: OpaquePointer) {
        self.raw = raw
    }

    deinit {
        sqlite3_close_v2(raw)
    }
}

public actor SQLiteKnowledgeStore: KnowledgeStore {
    private let connection: KnowledgeSQLiteConnection

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
            throw KnowledgeStoreError.openFailed(message)
        }

        do {
            try Self.execute(rawHandle, sql: "PRAGMA foreign_keys = ON;")
            try Self.execute(rawHandle, sql: "PRAGMA journal_mode = WAL;")
            try Self.execute(rawHandle, sql: "PRAGMA synchronous = NORMAL;")
            try Self.execute(rawHandle, sql: Self.schema)
            connection = KnowledgeSQLiteConnection(raw: rawHandle)
        } catch {
            sqlite3_close_v2(rawHandle)
            throw error
        }
    }

    public func loadDocument(
        sourceResourceID: UserFileResourceID
    ) async throws -> KnowledgeDocument? {
        let sql = """
        SELECT id, source_resource_id, display_name, media_type, page_count,
               metadata_json, created_at, updated_at
        FROM knowledge_documents
        WHERE source_resource_id = ?1
        LIMIT 1;
        """

        var statement: OpaquePointer?
        try prepare(connection.raw, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bind(sourceResourceID.rawValue, to: statement, index: 1)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return try decodeDocument(statement)
    }

    public func loadChunks(documentID: UUID) async throws -> [KnowledgeChunk] {
        let sql = """
        SELECT id, document_id, ordinal, page_start, page_end, text
        FROM knowledge_chunks
        WHERE document_id = ?1
        ORDER BY ordinal ASC;
        """

        var statement: OpaquePointer?
        try prepare(connection.raw, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        bind(documentID.uuidString, to: statement, index: 1)

        var chunks: [KnowledgeChunk] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = UUID(uuidString: text(statement, column: 0)),
                let storedDocumentID = UUID(uuidString: text(statement, column: 1))
            else {
                throw KnowledgeStoreError.corruptData("invalid chunk UUID")
            }

            chunks.append(
                KnowledgeChunk(
                    id: id,
                    documentID: storedDocumentID,
                    ordinal: Int(sqlite3_column_int64(statement, 2)),
                    pageStart: Int(sqlite3_column_int64(statement, 3)),
                    pageEnd: Int(sqlite3_column_int64(statement, 4)),
                    text: text(statement, column: 5)
                )
            )
        }
        return chunks
    }

    public func listDocuments() async throws -> [KnowledgeDocument] {
        let sql = """
        SELECT id, source_resource_id, display_name, media_type, page_count,
               metadata_json, created_at, updated_at
        FROM knowledge_documents
        ORDER BY updated_at DESC, display_name ASC;
        """

        var statement: OpaquePointer?
        try prepare(connection.raw, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        var documents: [KnowledgeDocument] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            documents.append(try decodeDocument(statement))
        }
        return documents
    }

    public func replaceDocument(
        _ document: KnowledgeDocument,
        chunks: [KnowledgeChunk]
    ) async throws {
        try validate(document: document, chunks: chunks)
        let metadataJSON = try encodeMetadata(document.metadata)
        let db = connection.raw

        try Self.execute(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            // A source resource has exactly one current Knowledge document.
            var removeOtherStatement: OpaquePointer?
            try prepare(
                db,
                sql: "DELETE FROM knowledge_documents WHERE source_resource_id = ?1 AND id <> ?2;",
                statement: &removeOtherStatement
            )
            bind(document.sourceResourceID.rawValue, to: removeOtherStatement, index: 1)
            bind(document.id.uuidString, to: removeOtherStatement, index: 2)
            try stepDone(removeOtherStatement, db: db)
            sqlite3_finalize(removeOtherStatement)

            let upsertSQL = """
            INSERT INTO knowledge_documents (
                id, source_resource_id, display_name, media_type, page_count,
                metadata_json, created_at, updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(id) DO UPDATE SET
                source_resource_id = excluded.source_resource_id,
                display_name = excluded.display_name,
                media_type = excluded.media_type,
                page_count = excluded.page_count,
                metadata_json = excluded.metadata_json,
                updated_at = excluded.updated_at;
            """

            var documentStatement: OpaquePointer?
            try prepare(db, sql: upsertSQL, statement: &documentStatement)
            bind(document.id.uuidString, to: documentStatement, index: 1)
            bind(document.sourceResourceID.rawValue, to: documentStatement, index: 2)
            bind(document.displayName, to: documentStatement, index: 3)
            bind(document.mediaType, to: documentStatement, index: 4)
            sqlite3_bind_int64(documentStatement, 5, sqlite3_int64(document.pageCount))
            bind(metadataJSON, to: documentStatement, index: 6)
            sqlite3_bind_double(documentStatement, 7, document.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(documentStatement, 8, document.updatedAt.timeIntervalSince1970)
            try stepDone(documentStatement, db: db)
            sqlite3_finalize(documentStatement)

            var deleteChunksStatement: OpaquePointer?
            try prepare(
                db,
                sql: "DELETE FROM knowledge_chunks WHERE document_id = ?1;",
                statement: &deleteChunksStatement
            )
            bind(document.id.uuidString, to: deleteChunksStatement, index: 1)
            try stepDone(deleteChunksStatement, db: db)
            sqlite3_finalize(deleteChunksStatement)

            let chunkSQL = """
            INSERT INTO knowledge_chunks (
                id, document_id, ordinal, page_start, page_end, text
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6);
            """

            for chunk in chunks {
                var statement: OpaquePointer?
                try prepare(db, sql: chunkSQL, statement: &statement)
                bind(chunk.id.uuidString, to: statement, index: 1)
                bind(chunk.documentID.uuidString, to: statement, index: 2)
                sqlite3_bind_int64(statement, 3, sqlite3_int64(chunk.ordinal))
                sqlite3_bind_int64(statement, 4, sqlite3_int64(chunk.pageStart))
                sqlite3_bind_int64(statement, 5, sqlite3_int64(chunk.pageEnd))
                bind(chunk.text, to: statement, index: 6)
                try stepDone(statement, db: db)
                sqlite3_finalize(statement)
            }

            try Self.execute(db, sql: "COMMIT;")
        } catch {
            try? Self.execute(db, sql: "ROLLBACK;")
            throw error
        }
    }

    private func validate(
        document: KnowledgeDocument,
        chunks: [KnowledgeChunk]
    ) throws {
        guard document.pageCount > 0 else {
            throw KnowledgeStoreError.invalidRecord("pageCount must be positive")
        }
        guard !document.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeStoreError.invalidRecord("displayName cannot be empty")
        }
        guard !document.mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeStoreError.invalidRecord("mediaType cannot be empty")
        }
        guard !chunks.isEmpty else {
            throw KnowledgeStoreError.invalidRecord("at least one chunk is required")
        }

        for (expectedOrdinal, chunk) in chunks.enumerated() {
            guard chunk.documentID == document.id else {
                throw KnowledgeStoreError.invalidRecord("chunk document identity mismatch")
            }
            guard chunk.ordinal == expectedOrdinal else {
                throw KnowledgeStoreError.invalidRecord("chunk ordinals must be contiguous from zero")
            }
            guard
                chunk.pageStart > 0,
                chunk.pageEnd >= chunk.pageStart,
                chunk.pageEnd <= document.pageCount
            else {
                throw KnowledgeStoreError.invalidRecord("chunk page provenance is outside the document")
            }
            guard !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KnowledgeStoreError.invalidRecord("chunk text cannot be empty")
            }
        }
    }

    private func decodeDocument(_ statement: OpaquePointer?) throws -> KnowledgeDocument {
        guard let id = UUID(uuidString: text(statement, column: 0)) else {
            throw KnowledgeStoreError.corruptData("invalid document UUID")
        }
        let sourceID = UserFileResourceID(rawValue: text(statement, column: 1))
        let metadataText = text(statement, column: 5)
        guard let metadataData = metadataText.data(using: .utf8) else {
            throw KnowledgeStoreError.corruptData("metadata is not UTF-8")
        }

        let metadata: [String: JSONValue]
        do {
            metadata = try JSONDecoder().decode([String: JSONValue].self, from: metadataData)
        } catch {
            throw KnowledgeStoreError.corruptData("invalid metadata JSON")
        }

        return KnowledgeDocument(
            id: id,
            sourceResourceID: sourceID,
            displayName: text(statement, column: 2),
            mediaType: text(statement, column: 3),
            pageCount: Int(sqlite3_column_int64(statement, 4)),
            metadata: metadata,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        )
    }

    private func encodeMetadata(_ metadata: [String: JSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        guard let string = String(data: data, encoding: .utf8) else {
            throw KnowledgeStoreError.invalidRecord("metadata could not be encoded as UTF-8")
        }
        return string
    }

    private func prepare(
        _ db: OpaquePointer,
        sql: String,
        statement: inout OpaquePointer?
    ) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw KnowledgeStoreError.statementFailed(errorMessage(db))
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer?, index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func stepDone(_ statement: OpaquePointer?, db: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw KnowledgeStoreError.executionFailed(errorMessage(db))
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
            throw KnowledgeStoreError.executionFailed(message)
        }
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS knowledge_documents (
        id TEXT PRIMARY KEY,
        source_resource_id TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        media_type TEXT NOT NULL,
        page_count INTEGER NOT NULL CHECK(page_count > 0),
        metadata_json TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS knowledge_chunks (
        id TEXT PRIMARY KEY,
        document_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
        page_start INTEGER NOT NULL CHECK(page_start > 0),
        page_end INTEGER NOT NULL CHECK(page_end >= page_start),
        text TEXT NOT NULL,
        FOREIGN KEY(document_id) REFERENCES knowledge_documents(id) ON DELETE CASCADE,
        UNIQUE(document_id, ordinal)
    );

    CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_document
        ON knowledge_chunks(document_id, ordinal);
    """
}
