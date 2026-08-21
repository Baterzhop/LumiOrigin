import Foundation

public enum ToolRisk: Int, Codable, Comparable, Sendable {
    case readOnly = 0
    case internalWrite = 1
    case userWrite = 2
    case externalAction = 3
    case system = 4
    case codeModification = 5

    public static func < (lhs: ToolRisk, rhs: ToolRisk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ToolCapability: String, Codable, Sendable {
    case readAppData
    case writeAppData
    case readUserFile
    case writeUserFile
    case writeUserMemory
    case deleteUserMemory
    case externalAction
    case systemCommand
    case modifyCode

    /// Persistent personal-memory mutation and user-file mutation are always
    /// approved per exact operation. A session grant would otherwise let a
    /// later model proposal reuse authority to change durable user data.
    public var supportsSessionGrant: Bool {
        switch self {
        case .writeUserFile, .writeUserMemory, .deleteUserMemory:
            return false
        default:
            return true
        }
    }
}

public struct ResourceScope: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case appData
        case file
        case userFile
        case userMemory
        case directory
        case externalService
        case system
        case codebase
    }

    public let kind: Kind
    public let identifier: String

    public init(kind: Kind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }

    /// Legacy/general file scope. New user-selected file tools should use `.userFile`.
    public static func file(_ identifier: String) -> ResourceScope {
        ResourceScope(kind: .file, identifier: identifier)
    }

    public static func userFile(_ id: UserFileResourceID) -> ResourceScope {
        ResourceScope(kind: .userFile, identifier: id.rawValue)
    }

    /// Exact logical memory-key scope. Callers must canonicalize and validate the
    /// key before constructing this scope so a grant cannot alias another memory.
    public static func userMemory(_ canonicalKey: String) -> ResourceScope {
        ResourceScope(kind: .userMemory, identifier: canonicalKey)
    }
}

public enum GrantDuration: String, Codable, Sendable {
    case once
    case session
}

public struct PermissionRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let capability: ToolCapability
    public let resource: ResourceScope
    public let reason: String
    public let resourceDisplayName: String?
    public let resourceLocationHint: String?
    /// Code-owned structured operation details. They are available to the
    /// approval UI and are also part of authorization matching. This prevents a
    /// grant for one exact mutation from silently authorizing a different one on
    /// the same resource.
    public let details: [String: String]

    public init(
        id: UUID = UUID(),
        capability: ToolCapability,
        resource: ResourceScope,
        reason: String,
        resourceDisplayName: String? = nil,
        resourceLocationHint: String? = nil,
        details: [String: String] = [:]
    ) {
        self.id = id
        self.capability = capability
        self.resource = resource
        self.reason = reason
        self.resourceDisplayName = resourceDisplayName
        self.resourceLocationHint = resourceLocationHint
        self.details = details
    }
}

public struct PermissionGrant: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let capability: ToolCapability
    public let resource: ResourceScope
    public let operationDetails: [String: String]
    public let duration: GrantDuration
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        capability: ToolCapability,
        resource: ResourceScope,
        operationDetails: [String: String] = [:],
        duration: GrantDuration,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.capability = capability
        self.resource = resource
        self.operationDetails = operationDetails
        self.duration = duration
        self.createdAt = createdAt
    }
}

public actor PermissionEngine {
    private var grants: [UUID: PermissionGrant] = [:]

    public init() {}

    @discardableResult
    public func grant(
        _ request: PermissionRequest,
        duration requestedDuration: GrantDuration
    ) -> PermissionGrant {
        // Some mutation capabilities are deliberately non-delegable across a
        // session. Enforce this below the UI so alternate callers cannot bypass it.
        let effectiveDuration: GrantDuration = request.capability.supportsSessionGrant
            ? requestedDuration
            : .once

        // Keep exactly one active grant for a capability/resource pair. Granting
        // a new exact operation for that resource invalidates any older operation
        // binding, so stale approvals cannot remain active in parallel.
        let duplicates = grants.values
            .filter { $0.capability == request.capability && $0.resource == request.resource }
            .map(\.id)
        for id in duplicates {
            grants.removeValue(forKey: id)
        }

        let grant = PermissionGrant(
            capability: request.capability,
            resource: request.resource,
            operationDetails: request.details,
            duration: effectiveDuration
        )
        grants[grant.id] = grant
        return grant
    }

    public func revoke(grantID: UUID) {
        grants.removeValue(forKey: grantID)
    }

    public func revokeAll() {
        grants.removeAll()
    }

    /// Returns true only when an explicit matching grant exists. The exact
    /// code-owned operation details are part of the binding in addition to the
    /// capability and resource. A one-time grant is consumed by the successful
    /// authorization attempt.
    public func authorize(_ request: PermissionRequest) -> Bool {
        guard let match = grants.values.first(where: {
            $0.capability == request.capability &&
            $0.resource == request.resource &&
            $0.operationDetails == request.details
        }) else {
            return false
        }

        if match.duration == .once {
            grants.removeValue(forKey: match.id)
        }
        return true
    }

    public func activeGrants() -> [PermissionGrant] {
        grants.values.sorted { $0.createdAt < $1.createdAt }
    }
}
