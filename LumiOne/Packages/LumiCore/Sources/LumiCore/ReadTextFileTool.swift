import Foundation

public struct ReadTextFileInput: Codable, Equatable, Sendable {
    public static let defaultMaxBytes = 1_048_576

    public let resourceID: UserFileResourceID
    public let maxBytes: Int

    public init(
        resourceID: UserFileResourceID,
        maxBytes: Int = defaultMaxBytes
    ) {
        self.resourceID = resourceID
        self.maxBytes = maxBytes
    }

    private enum CodingKeys: String, CodingKey {
        case resourceID
        case maxBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resourceID = try container.decode(UserFileResourceID.self, forKey: .resourceID)
        maxBytes = try container.decodeIfPresent(Int.self, forKey: .maxBytes)
            ?? Self.defaultMaxBytes
    }
}

public struct ReadTextFileOutput: Codable, Equatable, Sendable {
    public let resourceID: UserFileResourceID
    public let displayName: String
    public let content: String
    public let byteCount: Int
    public let truncated: Bool

    public init(
        resourceID: UserFileResourceID,
        displayName: String,
        content: String,
        byteCount: Int,
        truncated: Bool
    ) {
        self.resourceID = resourceID
        self.displayName = displayName
        self.content = content
        self.byteCount = byteCount
        self.truncated = truncated
    }
}

public struct ReadTextFileTool: Tool {
    public static let descriptor = ToolDescriptor(
        name: "file.readText",
        version: "2",
        summary: "Read UTF-8 text from one user-selected file already registered with Lumi.",
        risk: .readOnly,
        capability: .readUserFile,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "resourceID": .object([
                    "type": .string("string"),
                    "description": .string("Opaque Lumi resource ID for a file explicitly selected by the user. Never pass a filesystem path.")
                ]),
                "maxBytes": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(16_777_216),
                    "description": .string("Maximum bytes to read. Defaults to 1 MiB.")
                ])
            ]),
            "required": .array([.string("resourceID")]),
            "additionalProperties": .bool(false)
        ])
    )

    private let broker: any UserFileAccessBroker

    public init(broker: any UserFileAccessBroker = UnavailableUserFileAccessBroker()) {
        self.broker = broker
    }

    public func resource(for input: ReadTextFileInput) throws -> ResourceScope {
        _ = try broker.descriptor(for: input.resourceID)
        return .userFile(input.resourceID)
    }

    public func permissionRequest(for input: ReadTextFileInput) throws -> PermissionRequest {
        let descriptor = try broker.descriptor(for: input.resourceID)
        return PermissionRequest(
            capability: Self.descriptor.capability,
            resource: .userFile(input.resourceID),
            reason: Self.descriptor.summary,
            resourceDisplayName: descriptor.displayName,
            resourceLocationHint: descriptor.locationHint
        )
    }

    public func execute(_ input: ReadTextFileInput) async throws -> ReadTextFileOutput {
        guard (1...16_777_216).contains(input.maxBytes) else {
            throw UserFileAccessError.invalidLimit
        }

        let read = try await broker.readText(
            resourceID: input.resourceID,
            maxBytes: input.maxBytes
        )

        return ReadTextFileOutput(
            resourceID: read.descriptor.id,
            displayName: read.descriptor.displayName,
            content: read.content,
            byteCount: read.byteCount,
            truncated: read.truncated
        )
    }

    public func metadata(
        for input: ReadTextFileInput,
        output: ReadTextFileOutput
    ) -> [String: JSONValue] {
        [
            "encoding": .string("utf-8"),
            "resourceID": .string(output.resourceID.rawValue),
            "displayName": .string(output.displayName),
            "bytesRead": .number(Double(output.byteCount)),
            "truncated": .bool(output.truncated)
        ]
    }
}
