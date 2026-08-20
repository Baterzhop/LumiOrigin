import Foundation

public struct RememberMemoryInput: Codable, Equatable, Sendable {
    public let key: String
    public let kind: MemoryKind
    public let value: String
    public let confidence: Double
    public let expectedRevision: Int?

    public init(
        key: String,
        kind: MemoryKind,
        value: String,
        confidence: Double = 1.0,
        expectedRevision: Int? = nil
    ) {
        self.key = key
        self.kind = kind
        self.value = value
        self.confidence = confidence
        self.expectedRevision = expectedRevision
    }
}

/// Tool result intentionally omits the raw memory value. The model already
/// proposed that value, and duplicating it into hidden durable tool history
/// would create an unnecessary second retention path.
public struct RememberMemoryOutput: Codable, Equatable, Sendable {
    public let memoryID: UUID
    public let key: String
    public let kind: MemoryKind
    public let confidence: Double
    public let revision: Int
    public let created: Bool

    public init(result: MemoryWriteResult) {
        memoryID = result.record.id
        key = result.record.key
        kind = result.record.kind
        confidence = result.record.confidence
        revision = result.record.revision
        created = result.created
    }
}

public struct RememberMemoryTool: Tool {
    public static let descriptor = ToolDescriptor(
        name: "memory.remember",
        version: "1",
        summary: "Create or replace one persistent user memory after explicit approval.",
        risk: .userWrite,
        capability: .writeUserMemory,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "key": .object([
                    "type": .string("string"),
                    "description": .string("Stable logical memory key, for example profile.preferred_language.")
                ]),
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array(MemoryKind.allCases.map { .string($0.rawValue) })
                ]),
                "value": .object([
                    "type": .string("string"),
                    "description": .string("The exact user-memory value proposed for persistence.")
                ]),
                "confidence": .object([
                    "type": .string("number"),
                    "minimum": .number(0),
                    "maximum": .number(1)
                ]),
                "expectedRevision": .object([
                    "type": .array([.string("integer"), .string("null")]),
                    "minimum": .number(1),
                    "description": .string("Required when replacing an existing memory; omit only when creating a new key.")
                ])
            ]),
            "required": .array([
                .string("key"), .string("kind"), .string("value"), .string("confidence")
            ]),
            "additionalProperties": .bool(false)
        ])
    )

    private let service: MemoryService

    public init(service: MemoryService) {
        self.service = service
    }

    public func resource(for input: RememberMemoryInput) throws -> ResourceScope {
        .userMemory(try MemoryService.validatedKey(input.key))
    }

    public func permissionRequest(for input: RememberMemoryInput) throws -> PermissionRequest {
        let key = try MemoryService.validatedKey(input.key)
        let value = try MemoryService.validatedValue(input.value)
        try MemoryService.validateConfidence(input.confidence)
        if let expectedRevision = input.expectedRevision, expectedRevision < 1 {
            throw MemoryStoreError.revisionConflict(
                key: key,
                expected: expectedRevision,
                actual: nil
            )
        }

        var details: [String: String] = [
            "operation": "remember",
            "key": key,
            "kind": input.kind.rawValue,
            "proposedValue": value,
            "confidence": String(input.confidence)
        ]
        if let expectedRevision = input.expectedRevision {
            details["expectedRevision"] = String(expectedRevision)
        }

        return PermissionRequest(
            capability: Self.descriptor.capability,
            resource: .userMemory(key),
            reason: "Persist memory \(key) = \(Self.preview(value)).",
            resourceDisplayName: key,
            resourceLocationHint: "Persistent user memory",
            details: details
        )
    }

    public func execute(_ input: RememberMemoryInput) async throws -> RememberMemoryOutput {
        let result = try await service.remember(
            key: input.key,
            kind: input.kind,
            value: input.value,
            confidence: input.confidence,
            provenance: MemoryProvenance(sourceKind: .approvedModelProposal),
            expectedRevision: input.expectedRevision
        )
        return RememberMemoryOutput(result: result)
    }

    public func metadata(
        for input: RememberMemoryInput,
        output: RememberMemoryOutput
    ) -> [String: JSONValue] {
        [
            "memoryID": .string(output.memoryID.uuidString),
            "key": .string(output.key),
            "revision": .number(Double(output.revision)),
            "created": .bool(output.created),
            "provenance": .string(MemoryProvenance.SourceKind.approvedModelProposal.rawValue)
        ]
    }

    public func historyArguments(for input: RememberMemoryInput) throws -> JSONValue {
        let key = try MemoryService.validatedKey(input.key)
        try MemoryService.validateConfidence(input.confidence)
        var object: [String: JSONValue] = [
            "key": .string(key),
            "kind": .string(input.kind.rawValue),
            "value": .string("<redacted:persistent-memory-value>"),
            "confidence": .number(input.confidence)
        ]
        if let expectedRevision = input.expectedRevision {
            object["expectedRevision"] = .number(Double(expectedRevision))
        } else {
            object["expectedRevision"] = .null
        }
        return .object(object)
    }

    private static func preview(_ value: String) -> String {
        let flattened = value.replacingOccurrences(of: "\n", with: " ")
        if flattened.count <= 160 { return flattened }
        return String(flattened.prefix(157)) + "…"
    }
}

public struct ForgetMemoryInput: Codable, Equatable, Sendable {
    public let key: String
    public let expectedRevision: Int

    public init(key: String, expectedRevision: Int) {
        self.key = key
        self.expectedRevision = expectedRevision
    }
}

public struct ForgetMemoryOutput: Codable, Equatable, Sendable {
    public let memoryID: UUID?
    public let key: String
    public let forgotten: Bool
    public let deletedRevision: Int?

    public init(key: String, forgotten: UserMemoryRecord?) {
        self.memoryID = forgotten?.id
        self.key = key
        self.forgotten = forgotten != nil
        self.deletedRevision = forgotten?.revision
    }
}

public struct ForgetMemoryTool: Tool {
    public static let descriptor = ToolDescriptor(
        name: "memory.forget",
        version: "1",
        summary: "Permanently delete one persistent user memory after explicit approval.",
        risk: .userWrite,
        capability: .deleteUserMemory,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "key": .object([
                    "type": .string("string"),
                    "description": .string("Exact logical memory key to forget.")
                ]),
                "expectedRevision": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "description": .string("Exact currently active revision. Stale deletion requests fail closed.")
                ])
            ]),
            "required": .array([.string("key"), .string("expectedRevision")]),
            "additionalProperties": .bool(false)
        ])
    )

    private let service: MemoryService

    public init(service: MemoryService) {
        self.service = service
    }

    public func resource(for input: ForgetMemoryInput) throws -> ResourceScope {
        .userMemory(try MemoryService.validatedKey(input.key))
    }

    public func permissionRequest(for input: ForgetMemoryInput) throws -> PermissionRequest {
        let key = try MemoryService.validatedKey(input.key)
        guard input.expectedRevision >= 1 else {
            throw MemoryStoreError.revisionConflict(
                key: key,
                expected: input.expectedRevision,
                actual: nil
            )
        }
        return PermissionRequest(
            capability: Self.descriptor.capability,
            resource: .userMemory(key),
            reason: "Permanently forget memory \(key) at revision \(input.expectedRevision).",
            resourceDisplayName: key,
            resourceLocationHint: "Persistent user memory — permanent deletion",
            details: [
                "operation": "forget",
                "key": key,
                "expectedRevision": String(input.expectedRevision)
            ]
        )
    }

    public func execute(_ input: ForgetMemoryInput) async throws -> ForgetMemoryOutput {
        let key = try MemoryService.validatedKey(input.key)
        let forgotten = try await service.forget(
            key: key,
            expectedRevision: input.expectedRevision
        )
        return ForgetMemoryOutput(key: key, forgotten: forgotten)
    }

    public func metadata(
        for input: ForgetMemoryInput,
        output: ForgetMemoryOutput
    ) -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [
            "key": .string(output.key),
            "forgotten": .bool(output.forgotten)
        ]
        if let memoryID = output.memoryID {
            metadata["memoryID"] = .string(memoryID.uuidString)
        }
        if let revision = output.deletedRevision {
            metadata["deletedRevision"] = .number(Double(revision))
        }
        return metadata
    }
}
