import Foundation
import CSQLite

public actor SQLiteConversationStore: ConversationStore {
    public let databaseURL: URL
    private var database: OpaquePointer?

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public static func defaultStore() -> SQLiteConversationStore {
        SQLiteConversationStore(databaseURL: defaultDatabaseURL())
    }

    public static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL {
        if let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return base
                .appendingPathComponent("LumiOrigin", isDirectory: true)
                .appendingPathComponent("lumi.sqlite3")
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".lumi", isDirectory: true)
            .appendingPathComponent("lumi.sqlite3")
    }

    public func loadMessages(conversationID: UUID) throws -> [ChatMessage] {
        let db = try openIfNeeded()
        let statement = try prepare(
            "SELECT id, role, content, timestamp FROM messages WHERE conversation_id = ? ORDER BY timestamp ASC, rowid ASC;",
            db: db
        )
        defer { sqlite3_finalize(statement) }
        try bind(conversationID.uuidString, index: 1, statement: statement, db: db)

        var messages: [ChatMessage] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw ConversationStoreError.statementFailed(message(db))
            }

            guard
                let idText = text(statement, 0),
                let id = UUID(uuidString: idText),
                let roleText = text(statement, 1),
                let role = ChatRole(rawValue: roleText),
                let content = text(statement, 2)
            else { continue }

            messages.append(
                ChatMessage(
                    id: id,
                    role: role,
                    content: content,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                )
            )
        }
        return messages
    }

    public func append(_ chatMessage: ChatMessage, conversationID: UUID) throws {
        let db = try openIfNeeded()
        try exec("BEGIN IMMEDIATE;", db: db, migration: false)

        do {
            try ensureConversation(conversationID, timestamp: chatMessage.timestamp, db: db)
            let statement = try prepare(
                "INSERT OR REPLACE INTO messages(id, conversation_id, role, content, timestamp) VALUES (?, ?, ?, ?, ?);",
                db: db
            )
            defer { sqlite3_finalize(statement) }

            try bind(chatMessage.id.uuidString, index: 1, statement: statement, db: db)
            try bind(conversationID.uuidString, index: 2, statement: statement, db: db)
            try bind(chatMessage.role.rawValue, index: 3, statement: statement, db: db)
            try bind(chatMessage.content, index: 4, statement: statement, db: db)
            guard sqlite3_bind_double(statement, 5, chatMessage.timestamp.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE
            else {
                throw ConversationStoreError.writeFailed(message(db))
            }

            try exec("COMMIT;", db: db, migration: false)
        } catch {
            try? exec("ROLLBACK;", db: db, migration: false)
            throw error
        }
    }

    public func clear(conversationID: UUID) throws {
        let db = try openIfNeeded()
        let statement = try prepare("DELETE FROM conversations WHERE id = ?;", db: db)
        defer { sqlite3_finalize(statement) }
        try bind(conversationID.uuidString, index: 1, statement: statement, db: db)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ConversationStoreError.writeFailed(message(db))
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
            throw ConversationStoreError.openFailed(error.localizedDescription)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let detail = handle.map(message) ?? "SQLite status \(status)"
            if let handle { sqlite3_close(handle) }
            throw ConversationStoreError.openFailed(detail)
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
            timestamp REAL NOT NULL,
            FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_messages_conversation_timestamp
            ON messages(conversation_id, timestamp);
        INSERT OR IGNORE INTO schema_migrations(version, applied_at)
            VALUES (1, strftime('%s','now'));
        """
        try exec(sql, db: db, migration: true)
    }

    private func ensureConversation(_ id: UUID, timestamp: Date, db: OpaquePointer) throws {
        let insert = try prepare(
            "INSERT OR IGNORE INTO conversations(id, title, created_at, updated_at) VALUES (?, ?, ?, ?);",
            db: db
        )
        defer { sqlite3_finalize(insert) }
        try bind(id.uuidString, index: 1, statement: insert, db: db)
        try bind("Lumi Conversation", index: 2, statement: insert, db: db)
        guard sqlite3_bind_double(insert, 3, timestamp.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_double(insert, 4, timestamp.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(insert) == SQLITE_DONE
        else { throw ConversationStoreError.writeFailed(message(db)) }

        let update = try prepare("UPDATE conversations SET updated_at = ? WHERE id = ?;", db: db)
        defer { sqlite3_finalize(update) }
        guard sqlite3_bind_double(update, 1, timestamp.timeIntervalSince1970) == SQLITE_OK else {
            throw ConversationStoreError.writeFailed(message(db))
        }
        try bind(id.uuidString, index: 2, statement: update, db: db)
        guard sqlite3_step(update) == SQLITE_DONE else {
            throw ConversationStoreError.writeFailed(message(db))
        }
    }

    private func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ConversationStoreError.statementFailed(message(db))
        }
        return statement
    }

    private func bind(_ value: String, index: Int32, statement: OpaquePointer, db: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
        guard status == SQLITE_OK else {
            throw ConversationStoreError.writeFailed(message(db))
        }
    }

    private func exec(_ sql: String, db: OpaquePointer, migration: Bool) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            if migration {
                throw ConversationStoreError.migrationFailed(message(db))
            }
            throw ConversationStoreError.writeFailed(message(db))
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
