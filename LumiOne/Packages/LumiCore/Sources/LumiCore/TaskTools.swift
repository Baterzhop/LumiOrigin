import Foundation

public struct CreateTaskInput: Codable, Equatable, Sendable {
    public let title: String
    public let instruction: String
    public let maxAttempts: Int
    public let nextEligibleAtISO8601: String?

    public init(
        title: String,
        instruction: String,
        maxAttempts: Int = 3,
        nextEligibleAtISO8601: String? = nil
    ) {
        self.title = title
        self.instruction = instruction
        self.maxAttempts = maxAttempts
        self.nextEligibleAtISO8601 = nextEligibleAtISO8601
    }
}

public struct EditTaskInput: Codable, Equatable, Sendable {
    public let taskID: String
    public let title: String
    public let instruction: String
    public let maxAttempts: Int
    public let nextEligibleAtISO8601: String?
    public let expectedRevision: Int

    public init(
        taskID: String,
        title: String,
        instruction: String,
        maxAttempts: Int,
        nextEligibleAtISO8601: String? = nil,
        expectedRevision: Int
    ) {
        self.taskID = taskID
        self.title = title
        self.instruction = instruction
        self.maxAttempts = maxAttempts
        self.nextEligibleAtISO8601 = nextEligibleAtISO8601
        self.expectedRevision = expectedRevision
    }
}

public struct CancelTaskInput: Codable, Equatable, Sendable {
    public let taskID: String
    public let expectedRevision: Int
    public let reason: String?

    public init(taskID: String, expectedRevision: Int, reason: String? = nil) {
        self.taskID = taskID
        self.expectedRevision = expectedRevision
        self.reason = reason
    }
}

public struct TaskMutationOutput: Codable, Equatable, Sendable {
    public let taskID: String
    public let title: String
    public let state: TaskState
    public let revision: Int
    public let attemptCount: Int
    public let maxAttempts: Int
    public let nextEligibleAtISO8601: String?

    public init(record: TaskRecord) {
        taskID = record.id.description
        title = record.title
        state = record.state
        revision = record.revision
        attemptCount = record.attemptCount
        maxAttempts = record.maxAttempts
        nextEligibleAtISO8601 = record.nextEligibleAt.map(TaskToolTime.format)
    }
}

public struct CreateTaskTool: Tool {
    public static let descriptor = ToolDescriptor(
        name: "task.create",
        version: "1",
        summary: "Create one durable Lumi task as a draft after explicit approval.",
        risk: .userWrite,
        capability: .writeUserTask,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object([
                    "type": .string("string"),
                    "maxLength": .number(Double(TaskValidation.maximumTitleCharacters))
                ]),
                "instruction": .object([
                    "type": .string("string"),
                    "maxLength": .number(Double(TaskValidation.maximumInstructionCharacters)),
                    "description": .string("User-visible task instruction. It does not grant tool authority.")
                ]),
                "maxAttempts": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(Double(TaskValidation.maximumAttempts))
                ]),
                "nextEligibleAtISO8601": .object([
                    "type": .array([.string("string"), .string("null")]),
                    "description": .string("Optional ISO-8601 UTC/offset timestamp. This is eligibility metadata, not a background schedule.")
                ])
            ]),
            "required": .array([.string("title"), .string("instruction"), .string("maxAttempts")]),
            "additionalProperties": .bool(false)
        ])
    )

    private let service: TaskService

    public init(service: TaskService) {
        self.service = service
    }

    public func resource(for input: CreateTaskInput) throws -> ResourceScope {
        _ = try validated(input)
        return .newUserTask
    }

    public func permissionRequest(for input: CreateTaskInput) throws -> PermissionRequest {
        let value = try validated(input)
        return PermissionRequest(
            capability: Self.descriptor.capability,
            resource: .newUserTask,
            reason: "Create durable task ‘\(value.title)’ with instruction: \(Self.preview(value.instruction))",
            resourceDisplayName: value.title,
            resourceLocationHint: "Lumi Tasks — new persistent task",
            details: [
                "operation": "create",
                "title": value.title,
                "instruction": value.instruction,
                "maxAttempts": String(value.maxAttempts),
                "nextEligibleAt": value.nextEligibleAt.map(TaskToolTime.format) ?? "none"
            ]
        )
    }

    public func execute(_ input: CreateTaskInput) async throws -> TaskMutationOutput {
        let value = try validated(input)
        let record = try await service.create(
            title: value.title,
            instruction: value.instruction,
            maxAttempts: value.maxAttempts,
            nextEligibleAt: value.nextEligibleAt,
            actor: .approvedModel
        )
        return TaskMutationOutput(record: record)
    }

    public func metadata(for input: CreateTaskInput, output: TaskMutationOutput) -> [String: JSONValue] {
        [
            "taskID": .string(output.taskID),
            "state": .string(output.state.rawValue),
            "revision": .number(Double(output.revision)),
            "persistentMutation": .bool(true)
        ]
    }

    public func historyArguments(for input: CreateTaskInput) throws -> JSONValue {
        let value = try validated(input)
        return .object([
            "title": .string(value.title),
            "instruction": .string("<redacted:persistent-task-instruction>"),
            "maxAttempts": .number(Double(value.maxAttempts)),
            "nextEligibleAtISO8601": value.nextEligibleAt.map { .string(TaskToolTime.format($0)) } ?? .null
        ])
    }

    private func validated(_ input: CreateTaskInput) throws -> ValidatedTaskMutation {
        try ValidatedTaskMutation(
            title: input.title,
            instruction: input.instruction,
            maxAttempts: input.maxAttempts,
            nextEligibleAtISO8601: input.nextEligibleAtISO8601
        )
    }

    private static func preview(_ value: String) -> String {
        let flattened = value.replacingOccurrences(of: "\n", with: " ")
        if flattened.count <= 160 { return flattened }
        return String(flattened.prefix(157)) + "…"
    }
}

public struct EditTaskTool: Tool {
    public static let descriptor = ToolDescriptor(
        name: "task.edit",
        version: "1",
        summary: "Edit one durable Lumi task at an exact revision after explicit approval.",
        risk: .userWrite,
        capability: .writeUserTask,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "taskID": .object(["type": .string("string")]),
                "title": .object([
                    "type": .string("string"),
                    "maxLength": .number(Double(TaskValidation.maximumTitleCharacters))
                ]),
                "instruction": .object([
                    "type": .string("string"),
                    "maxLength": .number(Double(TaskValidation.maximumInstructionCharacters))
                ]),
                "maxAttempts": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(Double(TaskValidation.maximumAttempts))
                ]),
                "nextEligibleAtISO8601": .object([
                    "type": .array([.string("string"), .string("null")])
                ]),
                "expectedRevision": .object([
                    "type": .string("integer"),
                    "minimum": .number(1)
                ])
            ]),
            "required": .array([
                .string("taskID"), .string("title"), .string("instruction"),
                .string("maxAttempts"), .string("expectedRevision")
            ]),
            "additionalProperties": .bool(false)
        ])
    )

    private let service: TaskService

    public init(service: TaskService) {
        self.service = service
    }

    public func resource(for input: EditTaskInput) throws -> ResourceScope {
        .userTask(try TaskToolTime.taskID(input.taskID))
    }

    public func permissionRequest(for input: EditTaskInput) throws -> PermissionRequest {
        let id = try TaskToolTime.taskID(input.taskID)
        guard input.expectedRevision >= 1 else {
            throw TaskStoreError.revisionConflict(taskID: id, expected: input.expectedRevision, actual: nil)
        }
        let value = try ValidatedTaskMutation(
            title: input.title,
            instruction: input.instruction,
            maxAttempts: input.maxAttempts,
            nextEligibleAtISO8601: input.nextEligibleAtISO8601
        )
        return PermissionRequest(
            capability: Self.descriptor.capability,
            resource: .userTask(id),
            reason: "Edit durable task ‘\(value.title)’ at revision \(input.expectedRevision).",
            resourceDisplayName: value.title,
            resourceLocationHint: "Lumi Tasks — \(id.description)",
            details: [
                "operation": "edit",
                "taskID": id.description,
                "expectedRevision": String(input.expectedRevision),
                "title": value.title,
                "instruction": value.instruction,
                "maxAttempts": String(value.maxAttempts),
                "nextEligibleAt": value.nextEligibleAt.map(TaskToolTime.format) ?? "none"
            ]
        )
    }

    public func execute(_ input: EditTaskInput) async throws -> TaskMutationOutput {
        let id = try TaskToolTime.taskID(input.taskID)
        let value = try ValidatedTaskMutation(
            title: input.title,
            instruction: input.instruction,
            maxAttempts: input.maxAttempts,
            nextEligibleAtISO8601: input.nextEligibleAtISO8601
        )
        let record = try await service.edit(
            id: id,
            title: value.title,
            instruction: value.instruction,
            maxAttempts: value.maxAttempts,
            nextEligibleAt: value.nextEligibleAt,
            expectedRevision: input.expectedRevision,
            actor: .approvedModel,
            reason: "Approved model task edit"
        )
        return TaskMutationOutput(record: record)
    }

    public func metadata(for input: EditTaskInput, output: TaskMutationOutput) -> [String: JSONValue] {
        [
            "taskID": .string(output.taskID),
            "state": .string(output.state.rawValue),
            "revision": .number(Double(output.revision)),
            "persistentMutation": .bool(true)
        ]
    }

    public func historyArguments(for input: EditTaskInput) throws -> JSONValue {
        let id = try TaskToolTime.taskID(input.taskID)
        let title = try TaskValidation.title(input.title)
        _ = try TaskValidation.instruction(input.instruction)
        _ = try TaskValidation.maxAttempts(input.maxAttempts)
        return .object([
            "taskID": .string(id.description),
            "title": .string(title),
            "instruction": .string("<redacted:persistent-task-instruction>"),
            "maxAttempts": .number(Double(input.maxAttempts)),
            "nextEligibleAtISO8601": try TaskToolTime.optionalJSONDate(input.nextEligibleAtISO8601),
            "expectedRevision": .number(Double(input.expectedRevision))
        ])
    }
}

public struct CancelTaskTool: Tool {
    public static let descriptor = ToolDescriptor(
        name: "task.cancel",
        version: "1",
        summary: "Cancel one durable Lumi task at an exact revision after explicit approval.",
        risk: .userWrite,
        capability: .writeUserTask,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "taskID": .object(["type": .string("string")]),
                "expectedRevision": .object([
                    "type": .string("integer"),
                    "minimum": .number(1)
                ]),
                "reason": .object([
                    "type": .array([.string("string"), .string("null")]),
                    "maxLength": .number(Double(TaskValidation.maximumDetailCharacters))
                ])
            ]),
            "required": .array([.string("taskID"), .string("expectedRevision")]),
            "additionalProperties": .bool(false)
        ])
    )

    private let service: TaskService

    public init(service: TaskService) {
        self.service = service
    }

    public func resource(for input: CancelTaskInput) throws -> ResourceScope {
        .userTask(try TaskToolTime.taskID(input.taskID))
    }

    public func permissionRequest(for input: CancelTaskInput) throws -> PermissionRequest {
        let id = try TaskToolTime.taskID(input.taskID)
        guard input.expectedRevision >= 1 else {
            throw TaskStoreError.revisionConflict(taskID: id, expected: input.expectedRevision, actual: nil)
        }
        let reason = try TaskValidation.detail(input.reason)
        return PermissionRequest(
            capability: Self.descriptor.capability,
            resource: .userTask(id),
            reason: "Cancel durable task \(id.description) at revision \(input.expectedRevision).",
            resourceDisplayName: id.description,
            resourceLocationHint: "Lumi Tasks — cancellation",
            details: [
                "operation": "cancel",
                "taskID": id.description,
                "expectedRevision": String(input.expectedRevision),
                "reason": reason ?? "none"
            ]
        )
    }

    public func execute(_ input: CancelTaskInput) async throws -> TaskMutationOutput {
        let id = try TaskToolTime.taskID(input.taskID)
        let reason = try TaskValidation.detail(input.reason)
        let record = try await service.cancel(
            id: id,
            expectedRevision: input.expectedRevision,
            actor: .approvedModel,
            reason: reason ?? "Cancelled by approved model proposal"
        )
        return TaskMutationOutput(record: record)
    }

    public func metadata(for input: CancelTaskInput, output: TaskMutationOutput) -> [String: JSONValue] {
        [
            "taskID": .string(output.taskID),
            "state": .string(output.state.rawValue),
            "revision": .number(Double(output.revision)),
            "persistentMutation": .bool(true)
        ]
    }
}

private struct ValidatedTaskMutation: Sendable {
    let title: String
    let instruction: String
    let maxAttempts: Int
    let nextEligibleAt: Date?

    init(
        title: String,
        instruction: String,
        maxAttempts: Int,
        nextEligibleAtISO8601: String?
    ) throws {
        self.title = try TaskValidation.title(title)
        self.instruction = try TaskValidation.instruction(instruction)
        self.maxAttempts = try TaskValidation.maxAttempts(maxAttempts)
        self.nextEligibleAt = try TaskToolTime.parseOptional(nextEligibleAtISO8601)
    }
}

private enum TaskToolTime {
    static func taskID(_ raw: String) throws -> TaskID {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: normalized) else {
            throw TaskToolError.invalidTaskID(raw)
        }
        return TaskID(rawValue: uuid)
    }

    static func parseOptional(_ raw: String?) throws -> Date? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime, .withColonSeparatorInTimeZone]
        if let date = standard.date(from: normalized) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withDashSeparatorInDate, .withColonSeparatorInTime, .withColonSeparatorInTimeZone]
        if let date = fractional.date(from: normalized) { return date }

        throw TaskToolError.invalidISO8601(raw)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withDashSeparatorInDate, .withColonSeparatorInTime, .withColonSeparatorInTimeZone]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func optionalJSONDate(_ raw: String?) throws -> JSONValue {
        guard let date = try parseOptional(raw) else { return .null }
        return .string(format(date))
    }
}

public enum TaskToolError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalidTaskID(String)
    case invalidISO8601(String)

    public var description: String {
        switch self {
        case .invalidTaskID(let value):
            return "Invalid task ID: \(value)."
        case .invalidISO8601(let value):
            return "Invalid ISO-8601 task timestamp: \(value)."
        }
    }
}
