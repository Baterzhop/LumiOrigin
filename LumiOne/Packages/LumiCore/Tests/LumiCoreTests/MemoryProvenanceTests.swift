import Foundation
import XCTest
@testable import LumiCore

final class MemoryProvenanceTests: XCTestCase {
    func testExplicitUserStatementProvenanceSurvivesSQLiteReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-memory-provenance-\(UUID().uuidString)")
        let databaseURL = directory.appendingPathComponent("memory.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        let conversationID = UUID()
        let messageID = UUID()
        let provenance = MemoryProvenance(
            sourceKind: .explicitUserStatement,
            conversationID: conversationID,
            messageID: messageID,
            note: "Explicitly requested by the user"
        )

        let store = try SQLiteMemoryStore(url: databaseURL)
        let service = MemoryService(store: store)
        let created = try await service.remember(
            key: "profile.preferred.language",
            kind: .preference,
            value: "Ukrainian",
            confidence: 1.0,
            provenance: provenance
        )
        XCTAssertEqual(created.record.provenance, provenance)

        let reopened = try SQLiteMemoryStore(url: databaseURL)
        let loaded = try await reopened.load(key: "profile.preferred.language")
        XCTAssertEqual(loaded?.provenance.sourceKind, .explicitUserStatement)
        XCTAssertEqual(loaded?.provenance.conversationID, conversationID)
        XCTAssertEqual(loaded?.provenance.messageID, messageID)
        XCTAssertEqual(loaded?.provenance.note, "Explicitly requested by the user")
    }
}
