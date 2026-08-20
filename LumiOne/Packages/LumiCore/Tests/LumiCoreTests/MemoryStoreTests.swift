import Foundation
import XCTest
@testable import LumiCore

final class MemoryStoreTests: XCTestCase {
    func testCreateCanonicalizesAndSurvivesStoreReopen() async throws {
        let url = temporaryDatabaseURL()
        defer { cleanupDatabase(at: url) }

        let firstStore = try SQLiteMemoryStore(url: url)
        let firstService = MemoryService(store: firstStore)
        let result = try await firstService.remember(
            key: " Preferred   Motorcycle / Tire ",
            kind: .preference,
            value: "  Pirelli Diablo Rosso IV  ",
            confidence: 1.0,
            provenance: MemoryProvenance(sourceKind: .manualUserEntry)
        )

        XCTAssertTrue(result.created)
        XCTAssertEqual(result.record.key, "preferred.motorcycle.tire")
        XCTAssertEqual(result.record.value, "Pirelli Diablo Rosso IV")
        XCTAssertEqual(result.record.revision, 1)

        let reopened = try SQLiteMemoryStore(url: url)
        let loaded = try await reopened.load(key: "preferred.motorcycle.tire")
        XCTAssertEqual(loaded, result.record)
    }

    func testReplacementRequiresExactRevisionAndPreservesHistory() async throws {
        let url = temporaryDatabaseURL()
        defer { cleanupDatabase(at: url) }

        let store = try SQLiteMemoryStore(url: url)
        let service = MemoryService(store: store)
        let first = try await service.remember(
            key: "transport.favorite.brand",
            kind: .preference,
            value: "Ducati",
            provenance: MemoryProvenance(sourceKind: .explicitUserStatement)
        )

        do {
            _ = try await service.remember(
                key: "transport.favorite.brand",
                kind: .preference,
                value: "Porsche",
                provenance: MemoryProvenance(sourceKind: .approvedModelProposal)
            )
            XCTFail("Existing memory must not be overwritten without an exact revision")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(
                error,
                .revisionConflict(
                    key: "transport.favorite.brand",
                    expected: nil,
                    actual: 1
                )
            )
        }

        let second = try await service.remember(
            key: "transport.favorite.brand",
            kind: .preference,
            value: "Porsche",
            confidence: 0.9,
            provenance: MemoryProvenance(sourceKind: .approvedModelProposal),
            expectedRevision: first.record.revision
        )

        XCTAssertEqual(second.record.id, first.record.id)
        XCTAssertEqual(second.record.revision, 2)
        XCTAssertEqual(second.record.value, "Porsche")
        XCTAssertEqual(second.previousRevision, first.record.currentRevision)

        let history = try await store.history(memoryID: first.record.id)
        XCTAssertEqual(history.map(\.revision), [1, 2])
        XCTAssertEqual(history.map(\.value), ["Ducati", "Porsche"])
        XCTAssertEqual(history[0].id, first.record.currentRevision.id)
        XCTAssertEqual(history[1].id, second.record.currentRevision.id)
    }

    func testStaleRevisionCannotOverwriteNewerMemory() async throws {
        let url = temporaryDatabaseURL()
        defer { cleanupDatabase(at: url) }

        let store = try SQLiteMemoryStore(url: url)
        let service = MemoryService(store: store)
        let first = try await service.remember(
            key: "ui.language",
            kind: .preference,
            value: "Ukrainian",
            provenance: MemoryProvenance(sourceKind: .manualUserEntry)
        )
        _ = try await service.remember(
            key: "ui.language",
            kind: .preference,
            value: "German",
            provenance: MemoryProvenance(sourceKind: .manualUserEntry),
            expectedRevision: first.record.revision
        )

        do {
            _ = try await service.remember(
                key: "ui.language",
                kind: .preference,
                value: "English",
                provenance: MemoryProvenance(sourceKind: .manualUserEntry),
                expectedRevision: first.record.revision
            )
            XCTFail("A stale approved revision must fail closed")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(
                error,
                .revisionConflict(key: "ui.language", expected: 1, actual: 2)
            )
        }

        let current = try await service.load(key: "ui.language")
        XCTAssertEqual(current?.value, "German")
        XCTAssertEqual(current?.revision, 2)
    }

    func testForgetRequiresCurrentRevisionAndHardDeletesHistory() async throws {
        let url = temporaryDatabaseURL()
        defer { cleanupDatabase(at: url) }

        let store = try SQLiteMemoryStore(url: url)
        let service = MemoryService(store: store)
        let created = try await service.remember(
            key: "temporary.note",
            kind: .context,
            value: "Delete this later",
            provenance: MemoryProvenance(sourceKind: .manualUserEntry)
        )

        do {
            _ = try await service.forget(key: "temporary.note", expectedRevision: nil)
            XCTFail("Forget must require an exact active revision")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(
                error,
                .revisionConflict(key: "temporary.note", expected: nil, actual: 1)
            )
        }

        let forgotten = try await service.forget(
            key: "temporary.note",
            expectedRevision: created.record.revision
        )
        XCTAssertEqual(forgotten?.id, created.record.id)

        let current = try await service.load(key: "temporary.note")
        XCTAssertNil(current)
        let history = try await store.history(memoryID: created.record.id)
        XCTAssertTrue(history.isEmpty)

        let reopened = try SQLiteMemoryStore(url: url)
        let afterReopen = try await reopened.load(key: "temporary.note")
        XCTAssertNil(afterReopen)
    }

    func testValidationRejectsInvalidMemoryBeforePersistence() async throws {
        let url = temporaryDatabaseURL()
        defer { cleanupDatabase(at: url) }

        let store = try SQLiteMemoryStore(url: url)
        let service = MemoryService(store: store)

        do {
            _ = try await service.remember(
                key: "---",
                kind: .other,
                value: "value",
                provenance: MemoryProvenance(sourceKind: .manualUserEntry)
            )
            XCTFail("Meaningless key should fail")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(error, .invalidKey)
        }

        do {
            _ = try await service.remember(
                key: "valid.key",
                kind: .other,
                value: "   ",
                provenance: MemoryProvenance(sourceKind: .manualUserEntry)
            )
            XCTFail("Empty value should fail")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(error, .invalidValue)
        }

        do {
            _ = try await service.remember(
                key: "valid.key",
                kind: .other,
                value: "value",
                confidence: 1.1,
                provenance: MemoryProvenance(sourceKind: .manualUserEntry)
            )
            XCTFail("Out-of-range confidence should fail")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(error, .invalidConfidence(1.1))
        }

        let active = try await service.listActive()
        XCTAssertTrue(active.isEmpty)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-memory-tests-\(UUID().uuidString)")
            .appendingPathComponent("memory.sqlite3")
    }

    private func cleanupDatabase(at url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url.deletingLastPathComponent())
    }
}
