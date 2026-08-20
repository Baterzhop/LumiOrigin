import Foundation
@testable import LumiCore

final class TestUserFileBroker: UserFileAccessBroker, @unchecked Sendable {
    private struct Entry {
        let descriptor: UserFileDescriptor
        let data: Data
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
}
