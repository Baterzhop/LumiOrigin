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

    public func createConversation(id: UUID, title: String, createdAt: Date) throws -> Conversation {
        let cleanTitle = try Self.validatedTitle(title)
        let db = try openIfNeeded()
        let statement = try prepare(
            "INSERT OR IGNORE INTO conversations(id, title, created_at, updated_at) VALUES (?, ?, ?, ?);",
            db: db
        )
        defer { sqlite3_finalize(statement) }

        try bind(id.uuidString, index: 1, statement: statement, db: db)
        try bind(cleanTitle, index: 2, statement: statement, db: db)
        guard
            sqlite3_bind_double(statement, 3, createdAt.timeIntervalSince1970) == SQLITE_OK,
            sqlite3_bind_double(statement, 4, createdAt.timeIntervalSince1970) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_DONE
        else {
            throw ConversationStoreError.writeFailed(message(db))
        }

        guard let stored = try conversation(id: id) else {
            throw ConversationStoreError.writeFailed("Conversation insert completed without a readable row.")
        }
        return stored
    }

    public func conversation(id: UUID) throws -> Conversation? {
        let db = try openIfNeeded()
        let statement = try prepare(
            """
            SELECT
                c.id,
                c.title,
                c.created_at,
                c.updated_at,
                (SELECT COUNT(*) FROM messages m WHERE m.conversation_id = c.id) AS message_count
            FROM conversations c
            WHERE c.id = ?
            LIMIT 1;
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, index: 1, statement: statement, db: db)

        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else {
            throw ConversationStoreError.statementFailed(message(db))
        }
        return try decodeConversation(statement)
    }

    public func listConversations(limit: Int) throws -> [Conversation] {
        let finalLimit = max(0, min(limit, 500))
        guard finalLimit > 0 else { return [] }

        let db = try openIfNeeded()
        let statement = try prepare(
            """
            SELECT
                c.id,
                c.title,
                c.created_at,
                c.updated_at,
                COUNT(m.id) AS message_count
            FROM conversations c
            LEFT JOIN messages m ON m.conversation_id = c.id
            GROUP BY c.id, c.title, c.created_at, c.updated_at
            ORDER BY c.updated_at DESC, c.created_at DESC, c.id ASC
            LIMIT ?;
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int(statement, 1, Int32(finalLimit)) == SQLITE_OK else {
            throw ConversationStoreError.statementFailed(message(db))
        }

        var conversations: [Conversation] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw ConversationStoreError.statementFailed(message(db))
            }
            conversations.append(try decodeConversation(statement))
        }
        return conversations
    }

    public func renameConversation(id: UUID, title: String) throws -> Conversation {
        let cleanTitle = try Self.validatedTitle(title)
        let db = try openIfNeeded()
        let statement = try prepare(
            "UPDATE conversations SET title = ?, updated_at = ? WHERE id = ?;",
            db: db
        )
        defer { sqlite3_finalize(statement) }

        try bind(cleanTitle, index: 1, statement: statement, db: db)
        guard sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970) == SQLITE_OK else {
            throw ConversationStoreError.writeFailed(message(db))
        }
        try bind(id.uuidString, index: 3, statement: statement, db: db)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ConversationStoreError.writeFailed(message(db))
        }
        guard sqlite3_changes(db) > 0 else { throw ConversationStoreError.notFound }
        guard let updated = try conversation(id: id) else { throw ConversationStoreError.notFound }
        return updated
    }

    public func deleteConversation(id: UUID) throws {
        let db = try openIfNeeded()
        let statement = try prepare("DELETE FROM conversations WHERE id = ?;", db: db)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, index: 1, statement: statement, db: db)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ConversationStoreError.writeFailed(message(db))
        }
    }

    public func loadMessages(conversationID: UUID) throws -> [ChatMessage] {
        let db = try openIfNeeded()
        let statement = try prepare(
            "SELECT id, role, content, timestamp FROM messages WHERE conversation_id = ? ORDER BY timestamp ASC, rowid ASC;",
            db: db
        )
        defer { sqlite3_finalize(statement) }
        try bind(conversationID.uuidString, index: 1, statement: statement, db: db)

        var result: [ChatMessage] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw ConversationStoreError.statementFailed(message(db))
            }
            if let chatMessage = decodeMessage(statement) {
                result.append(chatMessage)
            }
        }
        return result
    }

    public func loadTranscriptPage(
        conversationID: UUID,
        before cursor: ConversationTranscriptCursor?,
        limit: Int
    ) throws -> ConversationTranscriptPage {
        let finalLimit = max(1, min(limit, 500))
        let db = try openIfNeeded()

        let sql: String
        if cursor == nil {
            sql = """
            SELECT id, role, content, timestamp
            FROM messages
            WHERE conversation_id = ?
            ORDER BY timestamp DESC, rowid DESC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT id, role, content, timestamp
            FROM messages
            WHERE conversation_id = ?
              AND (
                    timestamp < ?
                    OR (
                        timestamp = ?
                        AND rowid < COALESCE((SELECT rowid FROM messages WHERE id = ?), 9223372036854775807)
                    )
                  )
            ORDER BY timestamp DESC, rowid DESC
            LIMIT ?;
            """
        }

        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }
        try bind(conversationID.uuidString, index: 1, statement: statement, db: db)

        if let cursor {
            guard
                sqlite3_bind_double(statement, 2, cursor.timestamp.timeIntervalSince1970) == SQLITE_OK,
                sqlite3_bind_double(statement, 3, cursor.timestamp.timeIntervalSince1970) == SQLITE_OK
            else { throw ConversationStoreError.statementFailed(message(db)) }
            try bind(cursor.messageID.uuidString, index: 4, statement: statement, db: db)
            guard sqlite3_bind_int(statement, 5, Int32(finalLimit + 1)) == SQLITE_OK else {
                throw ConversationStoreError.statementFailed(message(db))
            }
        } else {
            guard sqlite3_bind_int(statement, 2, Int32(finalLimit + 1)) == SQLITE_OK else {
                throw ConversationStoreError.statementFailed(message(db))
            }
        }

        var descending: [ChatMessage] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw ConversationStoreError.statementFailed(message(db))
            }
            if let chatMessage = decodeMessage(statement) {
                descending.append(chatMessage)
            }
        }

        let hasOlder = descending.count > finalLimit
        if hasOlder { descending.removeLast(descending.count - finalLimit) }
        let chronological = Array(descending.reversed())
        let olderCursor = hasOlder ? chronological.first.map {
            ConversationTranscriptCursor(timestamp: $0.timestamp, messageID: $0.id)
        } : nil

        return ConversationTranscriptPage(
            messages: chronological,
            olderCursor: olderCursor,
            hasOlder: hasOlder
        )
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

            let update = try prepare("UPDATE conversations SET updated_at = MAX(updated_at, ?) WHERE id = ?;", db: db)
            defer { sqlite3_finalize(update) }
            guard sqlite3_bind_double(update, 1, chatMessage.timestamp.timeIntervalSince1970) == SQLITE_OK else {
                throw ConversationStoreError.writeFailed(message(db))
            }
            try bind(conversationID.uuidString, index: 2, statement: update, db: db)
            guard sqlite3_step(update) == SQLITE_DONE else {
                throw ConversationStoreError.writeFailed(message(db))
            }

            try exec("COMMIT;", db: db, migration: false)
        } catch {
            try? exec("ROLLBACK;", db: db, migration: false)
            throw error
        }
    }

    /// Clears messages but preserves the conversation itself so it can remain the selected chat.
    public func clear(conversationID: UUID) throws {
        let db = try openIfNeeded()
        try exec("BEGIN IMMEDIATE;", db: db, migration: false)
        do {
            let delete = try prepare("DELETE FROM messages WHERE conversation_id = ?;", db: db)
            try bind(conversationID.uuidString, index: 1, statement: delete, db: db)
            guard sqlite3_step(delete) == SQLITE_DONE else {
                sqlite3_finalize(delete)
                throw ConversationStoreError.writeFailed(message(db))
            }
            sqlite3_finalize(delete)

            let update = try prepare("UPDATE conversations SET updated_at = ? WHERE id = ?;", db: db)
            defer { sqlite3_finalize(update) }
            guard sqlite3_bind_double(update, 1, Date().timeIntervalSince1970) == SQLITE_OK else {
                throw ConversationStoreError.writeFailed(message(db))
            }
            try bind(conversationID.uuidString, index: 2, statement: update, db: db)
            guard sqlite3_step(update) == SQLITE_DONE else {
                throw ConversationStoreError.writeFailed(message(db))
            }
            try exec("COMMIT;", db: db, migration: false)
        } catch {
            try? exec("ROLLBACK;", db: db, migration: false)
            throw error
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
        CREATE INDEX IF NOT EXISTS idx_conversations_updated_at
            ON conversations(updated_at DESC);
        INSERT OR IGNORE INTO schema_migrations(version, applied_at)
            VALUES (1, strftime('%s','now'));
        INSERT OR IGNORE INTO schema_migrations(version, applied_at)
            VALUES (2, strftime('%s','now'));
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
        try bind("New chat", index: 2, statement: insert, db: db)
        guard sqlite3_bind_double(insert, 3, timestamp.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_double(insert, 4, timestamp.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(insert) == SQLITE_DONE
        else { throw ConversationStoreError.writeFailed(message(db)) }
    }

    private func decodeConversation(_ statement: OpaquePointer) throws -> Conversation {
        guard
            let idText = text(statement, 0),
            let id = UUID(uuidString: idText),
            let title = text(statement, 1)
        else {
            throw ConversationStoreError.statementFailed("Conversation row is incomplete.")
        }

        return Conversation(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            messageCount: Int(sqlite3_column_int64(statement, 4))
        )
    }

    private func decodeMessage(_ statement: OpaquePointer) -> ChatMessage? {
        guard
            let idText = text(statement, 0),
            let id = UUID(uuidString: idText),
            let roleText = text(statement, 1),
            let role = ChatRole(rawValue: roleText),
            let content = text(statement, 2)
        else { return nil }

        return ChatMessage(
            id: id,
            role: role,
            content: content,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        )
    }

    private static func validatedTitle(_ title: String) throws -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ConversationStoreError.invalidTitle }
        return String(clean.prefix(120))
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
