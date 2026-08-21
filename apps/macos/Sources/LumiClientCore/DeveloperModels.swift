import Foundation

struct DeveloperSessionCreateRequestDTO: Encodable, Sendable {
    let goal: String
}

struct ExplicitApprovalRequestDTO: Encodable, Sendable {
    let approvedByUser: Bool

    enum CodingKeys: String, CodingKey {
        case approvedByUser = "approved_by_user"
    }
}

public struct DeveloperStatusDTO: Decodable, Sendable {
    public let enabled: Bool
    public let repositoryOK: Bool
    public let repositoryRoot: String?
    public let baseBranch: String
    public let currentBranch: String?
    public let clean: Bool
    public let publisherConfigured: Bool
    public let localChecksEnabled: Bool
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case repositoryOK = "repository_ok"
        case repositoryRoot = "repository_root"
        case baseBranch = "base_branch"
        case currentBranch = "current_branch"
        case clean
        case publisherConfigured = "publisher_configured"
        case localChecksEnabled = "local_checks_enabled"
        case error
    }
}

public struct DeveloperFileChangeDTO: Decodable, Sendable, Hashable, Identifiable {
    public let path: String
    public let operation: String
    public let content: String
    public let reason: String

    public var id: String { path }
}

public struct DeveloperProposalDTO: Decodable, Sendable, Hashable {
    public let summary: String
    public let rationale: String
    public let changes: [DeveloperFileChangeDTO]
}

public struct DeveloperCheckResultDTO: Decodable, Sendable, Hashable, Identifiable {
    public let name: String
    public let command: [String]
    public let status: String
    public let returnCode: Int?
    public let output: String

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, command, status, output
        case returnCode = "return_code"
    }
}

public struct DeveloperSessionDTO: Decodable, Sendable, Identifiable {
    public let id: String
    public let goal: String
    public let status: String
    public let repositoryRoot: String
    public let baseBranch: String
    public let branchName: String?
    public let proposal: DeveloperProposalDTO?
    public let proposedDiff: String?
    public let checks: [String]
    public let validation: [DeveloperCheckResultDTO]
    public let commitSHA: String?
    public let prURL: String?
    public let error: String?
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, goal, status
        case repositoryRoot = "repository_root"
        case baseBranch = "base_branch"
        case branchName = "branch_name"
        case proposal
        case proposedDiff = "proposed_diff"
        case checks, validation
        case commitSHA = "commit_sha"
        case prURL = "pr_url"
        case error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
