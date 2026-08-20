import Foundation
import CSQLite

public enum SQLiteStoreError: Error, CustomStringConvertible, Sendable {
    case openFailed(String)
    case statementFailed(String)
    case executionFailed(String)
    case corruptData(String)

    public var description: String {
        switch self {
        case .openFailed(let message): return "SQLite open failed: \(message)"
        case .statementFailed(let message): return "SQLite statement failed: \(message)"
        case .executionFailed(let message): return "SQLite execution failed: \(message)"
        case .corruptData(let message): return "SQLite data is invalid: \(message)"
        }
    }
}

/// Owns the C SQLite handle and closes it exactly once.
///
/// Database access is serialized by `SQLiteConversationStore`. This wrapper keeps
/// the non-Sendable C pointer out of actor deinitialization while preserving RAII.
private final class SQLiteConnection: @unchecked Sendable {
    let raw: OpaquePointer

    init(raw: OpaquePointer) {
        self.raw = raw
    }

    deinit {
        sqlite3_close_v2(raw)
    }
}

public actor SQLiteConversationStore: ConversationStore {
    private let connection: SQLiteConnection

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
            throw SQLiteStoreError.openFailed(message)
        }

        do {
            try Self.execute(rawHandle, sql: "PRAGMA foreign_keys = ON;")
            try Self.execute(rawHandle, sql: "PRAGMA journal_mode = WAL;")
            try Self.execute(rawHandle, sql: "PRAGMA synchronous = NORMAL;")
            try Self.execute(rawHandle, sql: Self.schema)
            self.connection = SQLiteConnection(raw: rawHandle)
        } catch {
            sqlite3_close_v2(rawHandle)
            throw error
        }
    }

    public func loadConversation(id: UUID) async throws -> Conversation? {
        let db = connection.raw
        let conversationSQL = """
        SELECT title, created_at, updated_at
        FROM conversations
        WHERE id = ?1
        LIMIT 1;
        """

        var conversationStatement: OpaquePointer?
        try prepare(db, sql: conversationSQL, statement: &conversationStatement)
        defer { sqlite3_finalize(conversationStatement) }

        bind(id.uuidString, to: conversationStatement, index: 1)

        guard sqlite3_step(conversationStatement) == SQLITE_ROW else {
            return nil
        }

        let title = text(conversationStatement, column: 0)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(conversationStatement, 1))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(conversationStatement, 2))

        let messageSQL = """
        SELECT id, role, content, created_at
        FROM messages
        WHERE conversation_id = ?1
        ORDER BY sequence_number ASC;
        """

        var messageStatement: OpaquePointer?
        try prepare(db, sql: messageSQL, statement: &messageStatement)
        defer { sqlite3_finalize(messageStatement) }

        bind(id.uuidString, to: messageStatement, index: 1)

        var messages: [ChatMessage] = []
        while sqlite3_step(messageStatement) == SQLITE_ROW {
            guard
                let messageID = UUID(uuidString: text(messageStatement, column: 0)),
                let role = ChatRole(rawValue: text(messageStatement, column: 1))
            else {
                throw SQLiteStoreError.corruptData("invalid message identity or role")
            }

            messages.append(
                ChatMessage(
                    id: messageID,
                    role: role,
                    content: text(messageStatement, column: 2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(messageStatement, 3))
                )
            )
        }

        return Conversation(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages
        )
    }

    public func saveConversation(_ conversation: Conversation) async throws {
        let db = connection.raw

        try Self.execute(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try upsertConversation(conversation, db: db)
            try replaceMessages(conversation, db: db)
            try Self.execute(db, sql: "COMMIT;")
        } catch {
            try? Self.execute(db, sql: "ROLLBACK;")
            throw error
        }
    }

    private func upsertConversation(_ conversation: Conversation, db: OpaquePointer) throws {
        let sql = """
        INSERT INTO conversations (id, title, created_at, updated_at)
        VALUES (?1, ?2, ?3, ?4)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            updated_at = excluded.updated_at;
        """

        var statement: OpaquePointer?
        try prepare(db, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        bind(conversation.id.uuidString, to: statement, index: 1)
        bind(conversation.title, to: statement, index: 2)
        sqlite3_bind_double(statement, 3, conversation.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, conversation.updatedAt.timeIntervalSince1970)

        try stepDone(statement, db: db)
    }

    private func replaceMessages(_ conversation: Conversation, db: OpaquePointer) throws {
        var deleteStatement: OpaquePointer?
        try prepare(db, sql: "DELETE FROM messages WHERE conversation_id = ?1;", statement: &deleteStatement)
        defer { sqlite3_finalize(deleteStatement) }
        bind(conversation.id.uuidString, to: deleteStatement, index: 1)
        try stepDone(deleteStatement, db: db)

        let insertSQL = """
        INSERT INTO messages (id, conversation_id, role, content, created_at, sequence_number)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6);
        """

        for (index, message) in conversation.messages.enumerated() {
            var statement: OpaquePointer?
            try prepare(db, sql: insertSQL, statement: &statement)
            defer { sqlite3_finalize(statement) }

            bind(message.id.uuidString, to: statement, index: 1)
            bind(conversation.id.uuidString, to: statement, index: 2)
            bind(message.role.rawValue, to: statement, index: 3)
            bind(message.content, to: statement, index: 4)
            sqlite3_bind_double(statement, 5, message.createdAt.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 6, sqlite3_int64(index))
            try stepDone(statement, db: db)
        }
    }

    private func prepare(_ db: OpaquePointer, sql: String, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.statementFailed(errorMessage(db))
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer?, index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func stepDone(_ statement: OpaquePointer?, db: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.executionFailed(errorMessage(db))
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
            throw SQLiteStoreError.executionFailed(message)
        }
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS conversations (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at REAL NOT NULL,
        sequence_number INTEGER NOT NULL,
        FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_messages_conversation_sequence
        ON messages(conversation_id, sequence_number);
    """
}
