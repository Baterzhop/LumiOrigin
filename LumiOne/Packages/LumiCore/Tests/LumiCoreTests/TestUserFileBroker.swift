import Foundation
@testable import LumiCore

final class TestUserFileBroker: UserFileAccessBroker, UserFileWriteBroker, @unchecked Sendable {
    private struct Entry {
        let descriptor: UserFileDescriptor
        var data: Data
    }

    private let lock = NSLock()
    private var entries: [UserFileResourceID: Entry] = [:]

    @discardableResult
    func register(
        content: String,
        displayName: String = "fixture.txt",
        locationHint: String? = "/user-selected/fixture.txt",
        id: UserFileResourceID = UserFileResourceID()
    ) -> UserFileResourceID {
        let entry = Entry(
            descriptor: UserFileDescriptor(
                id: id,
                displayName: displayName,
                locationHint: locationHint
            ),
            data: Data(content.utf8)
        )

        lock.withLock {
            entries[id] = entry
        }
        return id
    }

    func descriptor(for id: UserFileResourceID) throws -> UserFileDescriptor {
        let entry = lock.withLock { entries[id] }
        guard let entry else {
            throw UserFileAccessError.unknownResource(id)
        }
        return entry.descriptor
    }

    func readText(
        resourceID: UserFileResourceID,
        maxBytes: Int
    ) async throws -> UserFileTextRead {
        guard (1...16_777_216).contains(maxBytes) else {
            throw UserFileAccessError.invalidLimit
        }

        let entry = lock.withLock { entries[resourceID] }
        guard let entry else {
            throw UserFileAccessError.unknownResource(resourceID)
        }

        let truncated = entry.data.count > maxBytes
        let data = truncated ? Data(entry.data.prefix(maxBytes)) : entry.data
        guard let content = String(data: data, encoding: .utf8) else {
            throw UserFileAccessError.notUTF8
        }

        return UserFileTextRead(
            descriptor: entry.descriptor,
            content: content,
            byteCount: data.count,
            truncated: truncated
        )
    }

    func writeText(
        resourceID: UserFileResourceID,
        content: String,
        requireEmpty: Bool
    ) async throws -> UserFileTextWrite {
        let data = Data(content.utf8)
        guard data.count <= 16_777_216 else {
            throw UserFileAccessError.invalidLimit
        }

        return try lock.withLock {
            guard var entry = entries[resourceID] else {
                throw UserFileAccessError.unknownResource(resourceID)
            }
            if requireEmpty && !entry.data.isEmpty {
                throw UserFileAccessError.outputNotEmpty(resourceID)
            }
            entry.data = data
            entries[resourceID] = entry
            return UserFileTextWrite(
                descriptor: entry.descriptor,
                byteCount: data.count
            )
        }
    }

    func content(resourceID: UserFileResourceID) throws -> String {
        guard let entry = lock.withLock({ entries[resourceID] }) else {
            throw UserFileAccessError.unknownResource(resourceID)
        }
        guard let text = String(data: entry.data, encoding: .utf8) else {
            throw UserFileAccessError.notUTF8
        }
        return text
    }
}
