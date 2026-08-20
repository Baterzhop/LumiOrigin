import Foundation
import LumiCore

public final class SecurityScopedFileCatalog: UserFileAccessBroker, @unchecked Sendable {
    private struct Record: Codable {
        let id: UserFileResourceID
        var displayName: String
        var locationHint: String
        var bookmarkData: Data

        var descriptor: UserFileDescriptor {
            UserFileDescriptor(
                id: id,
                displayName: displayName,
                locationHint: locationHint
            )
        }
    }

    private struct Store: Codable {
        var records: [Record]
    }

    private let storeURL: URL
    private let lock = NSLock()
    private var records: [UserFileResourceID: Record]

    public init(storeURL: URL) throws {
        self.storeURL = storeURL

        if FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                let data = try Data(contentsOf: storeURL)
                let store = try JSONDecoder().decode(Store.self, from: data)
                self.records = Dictionary(
                    uniqueKeysWithValues: store.records.map { ($0.id, $0) }
                )
            } catch {
                throw SecurityScopedFileCatalogError.invalidStore(
                    String(describing: error)
                )
            }
        } else {
            self.records = [:]
        }
    }

    @discardableResult
    public func register(url: URL) throws -> UserFileDescriptor {
        let canonical = url.standardizedFileURL
        let canonicalPath = canonical.path

        if let existing = lock.withLock({
            records.values.first(where: { $0.locationHint == canonicalPath })
        }) {
            return existing.descriptor
        }

        let bookmark: Data
        do {
            bookmark = try canonical.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw SecurityScopedFileCatalogError.bookmarkCreationFailed(
                String(describing: error)
            )
        }

        let id = UserFileResourceID()
        let record = Record(
            id: id,
            displayName: canonical.lastPathComponent,
            locationHint: canonicalPath,
            bookmarkData: bookmark
        )

        try lock.withLock {
            records[id] = record
            do {
                try persistLocked()
            } catch {
                records.removeValue(forKey: id)
                throw error
            }
        }

        return record.descriptor
    }

    public func remove(resourceID: UserFileResourceID) throws {
        try lock.withLock {
            let removed = records.removeValue(forKey: resourceID)
            do {
                try persistLocked()
            } catch {
                if let removed {
                    records[resourceID] = removed
                }
                throw error
            }
        }
    }

    public func allDescriptors() -> [UserFileDescriptor] {
        lock.withLock {
            records.values
                .map(\.descriptor)
                .sorted {
                    if $0.displayName == $1.displayName {
                        return $0.id.rawValue < $1.id.rawValue
                    }
                    return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
        }
    }

    public func descriptor(for id: UserFileResourceID) throws -> UserFileDescriptor {
        guard let record = lock.withLock({ records[id] }) else {
            throw UserFileAccessError.unknownResource(id)
        }
        return record.descriptor
    }

    public func readText(
        resourceID: UserFileResourceID,
        maxBytes: Int
    ) async throws -> UserFileTextRead {
        guard (1...16_777_216).contains(maxBytes) else {
            throw UserFileAccessError.invalidLimit
        }

        return try withSecurityScopedURL(resourceID: resourceID) { resolvedURL, descriptor in
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: resolvedURL)
            } catch {
                throw UserFileAccessError.resourceUnavailable(resourceID)
            }
            defer { try? handle.close() }

            let raw = try handle.read(upToCount: maxBytes + 1) ?? Data()
            let truncated = raw.count > maxBytes
            let data = truncated ? Data(raw.prefix(maxBytes)) : raw

            guard let content = String(data: data, encoding: .utf8) else {
                throw UserFileAccessError.notUTF8
            }

            return UserFileTextRead(
                descriptor: descriptor,
                content: content,
                byteCount: data.count,
                truncated: truncated
            )
        }
    }

    /// Internal platform boundary for adapters such as PDFKit. The URL never
    /// crosses into LumiCore, model input, chat history, or tool arguments.
    func withSecurityScopedURL<T>(
        resourceID: UserFileResourceID,
        _ body: (URL, UserFileDescriptor) throws -> T
    ) throws -> T {
        guard let record = lock.withLock({ records[resourceID] }) else {
            throw UserFileAccessError.unknownResource(resourceID)
        }

        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: record.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw UserFileAccessError.resourceUnavailable(resourceID)
        }

        let startedSecurityScope = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if startedSecurityScope {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        if isStale {
            try refreshBookmark(resourceID: resourceID, resolvedURL: resolvedURL)
        }

        let trustedDescriptor = try descriptor(for: resourceID)
        return try body(resolvedURL, trustedDescriptor)
    }

    private func refreshBookmark(
        resourceID: UserFileResourceID,
        resolvedURL: URL
    ) throws {
        let freshBookmark: Data
        do {
            freshBookmark = try resolvedURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw SecurityScopedFileCatalogError.bookmarkRefreshFailed(
                String(describing: error)
            )
        }

        try lock.withLock {
            guard var record = records[resourceID] else {
                throw UserFileAccessError.unknownResource(resourceID)
            }
            let previous = record
            record.bookmarkData = freshBookmark
            record.displayName = resolvedURL.lastPathComponent
            record.locationHint = resolvedURL.standardizedFileURL.path
            records[resourceID] = record

            do {
                try persistLocked()
            } catch {
                records[resourceID] = previous
                throw error
            }
        }
    }

    private func persistLocked() throws {
        let directory = storeURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let store = Store(records: Array(records.values))
            let data = try JSONEncoder().encode(store)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            throw SecurityScopedFileCatalogError.storeWriteFailed(
                String(describing: error)
            )
        }
    }
}

public enum SecurityScopedFileCatalogError: Error, CustomStringConvertible, Sendable {
    case invalidStore(String)
    case bookmarkCreationFailed(String)
    case bookmarkRefreshFailed(String)
    case storeWriteFailed(String)

    public var description: String {
        switch self {
        case .invalidStore(let details):
            return "The Lumi user-file catalog could not be loaded: \(details)"
        case .bookmarkCreationFailed(let details):
            return "The selected file could not be registered securely: \(details)"
        case .bookmarkRefreshFailed(let details):
            return "The selected file bookmark could not be refreshed: \(details)"
        case .storeWriteFailed(let details):
            return "The Lumi user-file catalog could not be saved: \(details)"
        }
    }
}
