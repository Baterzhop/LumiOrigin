import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct ToolDescriptor: Hashable, Codable, Sendable {
    public let name: String
    public let version: String
    public let summary: String
    public let risk: ToolRisk
    public let capability: ToolCapability

    public init(
        name: String,
        version: String,
        summary: String,
        risk: ToolRisk,
        capability: ToolCapability
    ) {
        self.name = name
        self.version = version
        self.summary = summary
        self.risk = risk
        self.capability = capability
    }

    public var registryKey: String { "\(name)@\(version)" }
}

public struct ToolWarning: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public protocol Tool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable

    static var descriptor: ToolDescriptor { get }

    func resource(for input: Input) throws -> ResourceScope
    func execute(_ input: Input) async throws -> Output
    func warnings(for input: Input, output: Output) -> [ToolWarning]
    func metadata(for input: Input, output: Output) -> [String: JSONValue]
}

public extension Tool {
    func warnings(for input: Input, output: Output) -> [ToolWarning] { [] }
    func metadata(for input: Input, output: Output) -> [String: JSONValue] { [:] }
}

public struct ToolCall: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let version: String
    public let arguments: Data

    public init(
        id: UUID = UUID(),
        name: String,
        version: String,
        arguments: Data
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.arguments = arguments
    }

    public static func encoding<Input: Encodable & Sendable>(
        name: String,
        version: String,
        input: Input
    ) throws -> ToolCall {
        ToolCall(
            name: name,
            version: version,
            arguments: try JSONEncoder().encode(input)
        )
    }
}

public struct ToolExecutionSuccess: Sendable, Equatable {
    public let callID: UUID
    public let descriptor: ToolDescriptor
    public let data: JSONValue
    public let warnings: [ToolWarning]
    public let metadata: [String: JSONValue]

    public init(
        callID: UUID,
        descriptor: ToolDescriptor,
        data: JSONValue,
        warnings: [ToolWarning] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.callID = callID
        self.descriptor = descriptor
        self.data = data
        self.warnings = warnings
        self.metadata = metadata
    }
}

public enum ToolExecutionOutcome: Sendable, Equatable {
    case permissionRequired(PermissionRequest)
    case success(ToolExecutionSuccess)
}

public enum ToolRuntimeError: Error, CustomStringConvertible, Sendable {
    case duplicateTool(String)
    case unknownTool(name: String, version: String)
    case invalidArguments(tool: String, details: String)
    case invalidOutput(tool: String, details: String)

    public var description: String {
        switch self {
        case .duplicateTool(let key):
            return "Tool registry contains duplicate tool \(key)."
        case .unknownTool(let name, let version):
            return "Unknown tool \(name)@\(version)."
        case .invalidArguments(let tool, let details):
            return "Invalid arguments for \(tool): \(details)"
        case .invalidOutput(let tool, let details):
            return "Invalid output from \(tool): \(details)"
        }
    }
}

private struct ErasedToolResult: Sendable {
    let data: JSONValue
    let warnings: [ToolWarning]
    let metadata: [String: JSONValue]
}

public struct AnyTool: Sendable {
    public let descriptor: ToolDescriptor

    private let resourceResolver: @Sendable (Data) throws -> ResourceScope
    private let executor: @Sendable (Data) async throws -> ErasedToolResult

    public init<T: Tool>(_ tool: T) {
        descriptor = T.descriptor

        resourceResolver = { data in
            do {
                let input = try JSONDecoder().decode(T.Input.self, from: data)
                return try tool.resource(for: input)
            } catch {
                throw ToolRuntimeError.invalidArguments(
                    tool: T.descriptor.registryKey,
                    details: String(describing: error)
                )
            }
        }

        executor = { data in
            let input: T.Input
            do {
                input = try JSONDecoder().decode(T.Input.self, from: data)
            } catch {
                throw ToolRuntimeError.invalidArguments(
                    tool: T.descriptor.registryKey,
                    details: String(describing: error)
                )
            }

            let output = try await tool.execute(input)
            do {
                let encoded = try JSONEncoder().encode(output)
                let structured = try JSONDecoder().decode(JSONValue.self, from: encoded)
                return ErasedToolResult(
                    data: structured,
                    warnings: tool.warnings(for: input, output: output),
                    metadata: tool.metadata(for: input, output: output)
                )
            } catch {
                throw ToolRuntimeError.invalidOutput(
                    tool: T.descriptor.registryKey,
                    details: String(describing: error)
                )
            }
        }
    }

    func permissionRequest(arguments: Data) throws -> PermissionRequest {
        PermissionRequest(
            capability: descriptor.capability,
            resource: try resourceResolver(arguments),
            reason: descriptor.summary
        )
    }

    func execute(arguments: Data) async throws -> ErasedToolResult {
        try await executor(arguments)
    }
}

public struct ToolRegistry: Sendable {
    private let tools: [String: AnyTool]

    public init(tools: [AnyTool]) throws {
        var indexed: [String: AnyTool] = [:]
        for tool in tools {
            let key = tool.descriptor.registryKey
            guard indexed[key] == nil else {
                throw ToolRuntimeError.duplicateTool(key)
            }
            indexed[key] = tool
        }
        self.tools = indexed
    }

    public func resolve(name: String, version: String) -> AnyTool? {
        tools["\(name)@\(version)"]
    }

    public var descriptors: [ToolDescriptor] {
        tools.values.map(\.descriptor).sorted { $0.registryKey < $1.registryKey }
    }
}

public actor ToolRuntime {
    private let registry: ToolRegistry
    private let permissions: PermissionEngine

    public init(registry: ToolRegistry, permissions: PermissionEngine) {
        self.registry = registry
        self.permissions = permissions
    }

    public func descriptors() -> [ToolDescriptor] {
        registry.descriptors
    }

    @discardableResult
    public func grant(
        _ request: PermissionRequest,
        duration: GrantDuration
    ) async -> PermissionGrant {
        await permissions.grant(request, duration: duration)
    }

    public func execute(_ call: ToolCall) async throws -> ToolExecutionOutcome {
        guard let tool = registry.resolve(name: call.name, version: call.version) else {
            throw ToolRuntimeError.unknownTool(name: call.name, version: call.version)
        }

        let request = try tool.permissionRequest(arguments: call.arguments)
        guard await permissions.authorize(request) else {
            return .permissionRequired(request)
        }

        let result = try await tool.execute(arguments: call.arguments)
        return .success(
            ToolExecutionSuccess(
                callID: call.id,
                descriptor: tool.descriptor,
                data: result.data,
                warnings: result.warnings,
                metadata: result.metadata
            )
        )
    }
}
