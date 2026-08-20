import Foundation

public actor ToolRegistry {
    private var tools: [String: any LumiTool] = [:]

    public init(tools: [any LumiTool] = []) {
        for tool in tools {
            self.tools[tool.definition.name] = tool
        }
    }

    public func register(_ tool: any LumiTool) {
        tools[tool.definition.name] = tool
    }

    public func unregister(name: String) {
        tools.removeValue(forKey: name)
    }

    public func tool(named name: String) -> (any LumiTool)? {
        tools[name]
    }

    public func definitions() -> [ToolDefinition] {
        tools.values
            .map(\.definition)
            .sorted { $0.name < $1.name }
    }
}

public struct ToolPermissionPolicy: Sendable {
    public let allowLowRiskReadOnlyWithoutConfirmation: Bool
    public let writeToolsEnabled: Bool

    public init(
        allowLowRiskReadOnlyWithoutConfirmation: Bool = true,
        writeToolsEnabled: Bool = false
    ) {
        self.allowLowRiskReadOnlyWithoutConfirmation = allowLowRiskReadOnlyWithoutConfirmation
        self.writeToolsEnabled = writeToolsEnabled
    }

    public func evaluate(
        definition: ToolDefinition,
        call: ToolCall,
        confirmation: ToolConfirmation?
    ) -> ToolPermissionDecision {
        if definition.access != .readOnly, !writeToolsEnabled {
            return .deny("Write and destructive tools are disabled by the current Lumi security policy.")
        }

        if definition.access == .destructive {
            return .deny("Destructive tools are not enabled in ToolRuntime V1.")
        }

        let needsConfirmation = definition.requiresConfirmation
            || definition.risk != .low
            || !allowLowRiskReadOnlyWithoutConfirmation

        guard needsConfirmation else {
            return .allow("Low-risk read-only tool allowed by policy.")
        }

        guard let confirmation else {
            return .requireConfirmation("This tool requires explicit confirmation before execution.")
        }

        guard confirmation.callID == call.id else {
            return .deny("Confirmation does not match this tool call.")
        }

        guard confirmation.approved else {
            return .deny("The user rejected this tool call.")
        }

        return .allow("Explicit confirmation approved this read-only tool call.")
    }
}

public actor ToolRuntime {
    private let registry: ToolRegistry
    private let policy: ToolPermissionPolicy
    private let auditStore: any ToolAuditStoring
    private var lastAuditIssue: String?

    public init(
        registry: ToolRegistry,
        policy: ToolPermissionPolicy = ToolPermissionPolicy(),
        auditStore: any ToolAuditStoring = InMemoryToolAuditStore()
    ) {
        self.registry = registry
        self.policy = policy
        self.auditStore = auditStore
    }

    public func availableTools() async -> [ToolDefinition] {
        await registry.definitions()
    }

    public func execute(
        _ call: ToolCall,
        confirmation: ToolConfirmation? = nil
    ) async -> ToolResult {
        let startedAt = Date()

        guard let tool = await registry.tool(named: call.toolName) else {
            let permission = ToolPermissionDecision.deny("Unknown tool name.")
            let result = ToolResult(
                callID: call.id,
                toolName: call.toolName,
                status: .failed,
                error: ToolRuntimeError.toolNotFound(call.toolName).localizedDescription,
                durationMs: elapsedMs(since: startedAt)
            )
            await audit(call: call, definition: nil, permission: permission, result: result, startedAt: startedAt)
            return result
        }

        let definition = tool.definition

        do {
            try validate(arguments: call.arguments, against: definition)
        } catch {
            let permission = ToolPermissionDecision.deny("Tool arguments failed schema validation.")
            let result = ToolResult(
                callID: call.id,
                toolName: call.toolName,
                status: .failed,
                error: error.localizedDescription,
                durationMs: elapsedMs(since: startedAt)
            )
            await audit(call: call, definition: definition, permission: permission, result: result, startedAt: startedAt)
            return result
        }

        let permission = policy.evaluate(
            definition: definition,
            call: call,
            confirmation: confirmation
        )

        switch permission.status {
        case .denied:
            let result = ToolResult(
                callID: call.id,
                toolName: call.toolName,
                status: .denied,
                error: permission.reason,
                durationMs: elapsedMs(since: startedAt)
            )
            await audit(call: call, definition: definition, permission: permission, result: result, startedAt: startedAt)
            return result

        case .confirmationRequired:
            let result = ToolResult(
                callID: call.id,
                toolName: call.toolName,
                status: .confirmationRequired,
                error: permission.reason,
                durationMs: elapsedMs(since: startedAt)
            )
            await audit(call: call, definition: definition, permission: permission, result: result, startedAt: startedAt)
            return result

        case .allowed:
            break
        }

        let result: ToolResult
        do {
            let output = try await Self.executeWithTimeout(
                tool: tool,
                arguments: call.arguments,
                timeoutSeconds: definition.timeoutSeconds
            )
            result = ToolResult(
                callID: call.id,
                toolName: call.toolName,
                status: .success,
                output: output,
                durationMs: elapsedMs(since: startedAt),
                trust: .untrusted
            )
        } catch is CancellationError {
            result = ToolResult(
                callID: call.id,
                toolName: call.toolName,
                status: .cancelled,
                error: ToolRuntimeError.cancelled.localizedDescription,
                durationMs: elapsedMs(since: startedAt)
            )
        } catch ToolRuntimeError.timeout {
            result = ToolResult(
                callID: call.id,
                toolName: call.toolName,
                status: .timeout,
                error: ToolRuntimeError.timeout.localizedDescription,
                durationMs: elapsedMs(since: startedAt)
            )
        } catch {
            result = ToolResult(
                callID: call.id,
                toolName: call.toolName,
                status: .failed,
                error: error.localizedDescription,
                durationMs: elapsedMs(since: startedAt)
            )
        }

        await audit(call: call, definition: definition, permission: permission, result: result, startedAt: startedAt)
        return result
    }

    public func recentAudit(limit: Int = 50) async -> [ToolAuditEvent] {
        do {
            let events = try await auditStore.recent(limit: limit)
            lastAuditIssue = nil
            return events
        } catch {
            lastAuditIssue = error.localizedDescription
            return []
        }
    }

    public func auditIssue() -> String? {
        lastAuditIssue
    }

    private func validate(arguments: [String: ToolValue], against definition: ToolDefinition) throws {
        let schemaByName = Dictionary(uniqueKeysWithValues: definition.inputSchema.map { ($0.name, $0) })

        for field in definition.inputSchema where field.required {
            guard arguments[field.name] != nil else {
                throw ToolRuntimeError.invalidArguments("Missing required field `\(field.name)`.")
            }
        }

        for (name, value) in arguments {
            guard let field = schemaByName[name] else {
                throw ToolRuntimeError.invalidArguments("Unknown field `\(name)` for tool `\(definition.name)`.")
            }
            guard matches(value, type: field.type) else {
                throw ToolRuntimeError.invalidArguments(
                    "Field `\(name)` must have type `\(field.type.rawValue)`."
                )
            }
        }
    }

    private func matches(_ value: ToolValue, type: ToolValueType) -> Bool {
        switch (value, type) {
        case (.string, .string), (.integer, .integer), (.number, .number), (.boolean, .boolean),
             (.array, .array), (.object, .object):
            return true
        default:
            return false
        }
    }

    private func audit(
        call: ToolCall,
        definition: ToolDefinition?,
        permission: ToolPermissionDecision,
        result: ToolResult,
        startedAt: Date
    ) async {
        let event = ToolAuditEvent(
            call: call,
            definition: definition,
            permission: permission,
            resultStatus: result.status,
            error: result.error,
            startedAt: startedAt,
            finishedAt: Date()
        )

        do {
            try await auditStore.append(event)
            lastAuditIssue = nil
        } catch {
            lastAuditIssue = error.localizedDescription
        }
    }

    private func elapsedMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    private static func executeWithTimeout(
        tool: any LumiTool,
        arguments: [String: ToolValue],
        timeoutSeconds: Int
    ) async throws -> ToolValue {
        try await withThrowingTaskGroup(of: ToolValue.self) { group in
            group.addTask {
                try await tool.execute(arguments: arguments)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                throw ToolRuntimeError.timeout
            }

            guard let first = try await group.next() else {
                group.cancelAll()
                throw ToolRuntimeError.executionFailed("Tool returned no result.")
            }
            group.cancelAll()
            return first
        }
    }
}

public actor InMemoryToolAuditStore: ToolAuditStoring {
    private var events: [ToolAuditEvent] = []

    public init() {}

    public func append(_ event: ToolAuditEvent) {
        events.append(event)
    }

    public func recent(limit: Int) -> [ToolAuditEvent] {
        Array(events.suffix(max(0, limit)).reversed())
    }
}
