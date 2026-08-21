import Foundation

public struct UserFileResourceID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID().uuidString.lowercased()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public struct UserFileDescriptor: Equatable, Sendable {
    public let id: UserFileResourceID
    public let displayName: String
    public let locationHint: String?

    public init(
        id: UserFileResourceID,
        displayName: String,
        locationHint: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.locationHint = locationHint
    }
}

public struct UserFileTextRead: Equatable, Sendable {
    public let descriptor: UserFileDescriptor
    public let content: String
    public let byteCount: Int
    public let truncated: Bool

    public init(
        descriptor: UserFileDescriptor,
        content: String,
        byteCount: Int,
        truncated: Bool
    ) {
        self.descriptor = descriptor
        self.content = content
        self.byteCount = byteCount
        self.truncated = truncated
    }
}

public struct UserFileTextWrite: Equatable, Sendable {
    public let descriptor: UserFileDescriptor
    public let byteCount: Int

    public init(descriptor: UserFileDescriptor, byteCount: Int) {
        self.descriptor = descriptor
        self.byteCount = byteCount
    }
}

public protocol UserFileAccessBroker: Sendable {
    /// Returns trusted metadata only for resources explicitly registered by the host app.
    func descriptor(for id: UserFileResourceID) throws -> UserFileDescriptor

    /// Reads a previously registered resource. Implementations own platform-specific
    /// access mechanics such as security-scoped bookmarks.
    func readText(
        resourceID: UserFileResourceID,
        maxBytes: Int
    ) async throws -> UserFileTextRead
}

/// Separate mutation boundary. Read-only brokers do not automatically gain write
/// authority. A host must deliberately provide an implementation for user-file writes.
public protocol UserFileWriteBroker: Sendable {
    func descriptor(for id: UserFileResourceID) throws -> UserFileDescriptor

    /// Writes UTF-8 text only to a previously registered output resource. Phase 8
    /// requires `requireEmpty == true`, preventing silent overwrite of an existing file.
    func writeText(
        resourceID: UserFileResourceID,
        content: String,
        requireEmpty: Bool
    ) async throws -> UserFileTextWrite
}

public enum UserFileAccessError: Error, CustomStringConvertible, Sendable {
    case unknownResource(UserFileResourceID)
    case invalidLimit
    case notUTF8
    case accessDenied(UserFileResourceID)
    case resourceUnavailable(UserFileResourceID)
    case outputNotEmpty(UserFileResourceID)
    case writeFailed(UserFileResourceID, String)

    public var description: String {
        switch self {
        case .unknownResource(let id):
            return "Unknown user-file resource \(id.rawValue)."
        case .invalidLimit:
            return "maxBytes must be between 1 and 16 MiB."
        case .notUTF8:
            return "The selected file is not valid UTF-8 text."
        case .accessDenied(let id):
            return "Access to user-file resource \(id.rawValue) was denied by the platform."
        case .resourceUnavailable(let id):
            return "User-file resource \(id.rawValue) is no longer available."
        case .outputNotEmpty(let id):
            return "Output user-file resource \(id.rawValue) is not empty; Lumi will not overwrite it."
        case .writeFailed(let id, let detail):
            return "Writing user-file resource \(id.rawValue) failed: \(detail)"
        }
    }
}

/// Safe default used when a host has not installed a platform file catalog.
/// It never resolves or reads any resource.
public struct UnavailableUserFileAccessBroker: UserFileAccessBroker, Sendable {
    public init() {}

    public func descriptor(for id: UserFileResourceID) throws -> UserFileDescriptor {
        throw UserFileAccessError.unknownResource(id)
    }

    public func readText(
        resourceID: UserFileResourceID,
        maxBytes: Int
    ) async throws -> UserFileTextRead {
        throw UserFileAccessError.unknownResource(resourceID)
    }
}
