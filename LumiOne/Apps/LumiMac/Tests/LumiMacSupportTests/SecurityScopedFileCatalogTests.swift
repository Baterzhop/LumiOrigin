import Foundation
import XCTest
import LumiCore
@testable import LumiMacSupport

final class SecurityScopedFileCatalogTests: XCTestCase {
    func testSelectedFileSurvivesCatalogReopenAndCanBeRead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiFileCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let selectedURL = root.appendingPathComponent("selected.txt")
        try Data("persisted selection".utf8).write(to: selectedURL)
        let storeURL = root.appendingPathComponent("catalog.json")

        let firstCatalog = try SecurityScopedFileCatalog(storeURL: storeURL)
        let registered = try firstCatalog.register(url: selectedURL)
        XCTAssertEqual(registered.displayName, "selected.txt")
        XCTAssertFalse(registered.id.rawValue.contains(selectedURL.path))

        let reopened = try SecurityScopedFileCatalog(storeURL: storeURL)
        let descriptors = reopened.allDescriptors()
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.id, registered.id)
        XCTAssertEqual(descriptors.first?.displayName, "selected.txt")

        let read = try await reopened.readText(
            resourceID: registered.id,
            maxBytes: 1024
        )
        XCTAssertEqual(read.content, "persisted selection")
        XCTAssertFalse(read.truncated)
    }

    func testRegisteringSameSelectedFileReusesStableResourceID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiFileCatalogDedupe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let selectedURL = root.appendingPathComponent("same.txt")
        try Data("same".utf8).write(to: selectedURL)
        let catalog = try SecurityScopedFileCatalog(
            storeURL: root.appendingPathComponent("catalog.json")
        )

        let first = try catalog.register(url: selectedURL)
        let second = try catalog.register(url: selectedURL)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(catalog.allDescriptors().count, 1)
    }

    func testRegisteredEmptyOutputCanBeWrittenOnceButNotOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiFileCatalogWrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outputURL = root.appendingPathComponent("output.csv")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: Data()))
        let catalog = try SecurityScopedFileCatalog(
            storeURL: root.appendingPathComponent("catalog.json")
        )
        let output = try catalog.register(url: outputURL)

        let first = try await catalog.writeText(
            resourceID: output.id,
            content: "name,value\r\nA,1\r\n",
            requireEmpty: true
        )
        XCTAssertEqual(first.descriptor.id, output.id)
        XCTAssertEqual(first.byteCount, "name,value\r\nA,1\r\n".utf8.count)

        let read = try await catalog.readText(resourceID: output.id, maxBytes: 1024)
        XCTAssertEqual(read.content, "name,value\r\nA,1\r\n")

        do {
            _ = try await catalog.writeText(
                resourceID: output.id,
                content: "malicious overwrite",
                requireEmpty: true
            )
            XCTFail("Phase 8 output resources must not be silently overwritten")
        } catch let error as UserFileAccessError {
            guard case .outputNotEmpty(let id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(id, output.id)
        }

        let after = try await catalog.readText(resourceID: output.id, maxBytes: 1024)
        XCTAssertEqual(after.content, "name,value\r\nA,1\r\n")
    }

    func testUnknownResourceFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiFileCatalogUnknown-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let catalog = try SecurityScopedFileCatalog(
            storeURL: root.appendingPathComponent("catalog.json")
        )
        let unknown = UserFileResourceID(rawValue: "invented-by-model")

        XCTAssertThrowsError(try catalog.descriptor(for: unknown))
        do {
            _ = try await catalog.readText(resourceID: unknown, maxBytes: 100)
            XCTFail("Unknown resources must fail closed")
        } catch let error as UserFileAccessError {
            XCTAssertEqual(error.description, "Unknown user-file resource invented-by-model.")
        }
    }
}
