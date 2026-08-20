import Foundation

public actor AgentRuntime {
    private let store: any ConversationStore
    private let model: any ModelProvider
    private let toolRuntime: ToolRuntime?
    private let contextProvider: (any ModelContextProvider)?
    private let maxToolSteps: Int

    private var pendingExecutions: [UUID: PendingExecution] = [:]

    public private(set) var phase: RuntimePhase = .idle
    public private(set) var lastError: String?

    public init(
        store: any ConversationStore,
        model: any ModelProvider,
        toolRuntime: ToolRuntime? = nil,
        contextProvider: (any ModelContextProvider)? = nil,
        maxToolSteps: Int = 8
    ) {
        self.store = store
        self.model = model
        self.toolRuntime = toolRuntime
        self.contextProvider = contextProvider
        self.maxToolSteps = max(1, maxToolSteps)
    }

    public func send(
        _ text: String,
        conversationID: UUID,
        title: String = "New conversation"
    ) async throws -> RuntimeOutcome {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw AgentRuntimeError.emptyInput
        }

        guard !hasPendingExecution(for: conversationID) else {
            throw AgentRuntimeError.pendingPermissionExists
        }

        do {
            phase = .loadingConversation
            lastError = nil

            var conversation = try await store.loadConversation(id: conversationID)
                ?? Conversation(id: conversationID, title: title)

            if conversation.messages.isEmpty, conversation.title == "New conversation" {
                conversation.title = Self.makeTitle(from: normalized)
            }

            let userMessage = ChatMessage(role: .user, content: normalized)
            conversation.messages.append(userMessage)
            conversation.updatedAt = Date()

            phase = .persistingUserMessage
            try await store.saveConversation(conversation)

            let contextSnapshot: ModelContextSnapshot?
            if let contextProvider {
                phase = .retrievingContext
                contextSnapshot = try await contextProvider.context(for: normalized)
            } else {
                contextSnapshot = nil
            }

            return try await continueRun(
                conversation: conversation,
                conversationID: conversationID,
                completedToolSteps: 0,
                contextSnapshot: contextSnapshot,
                transientToolEvents: [:]
            )
        } catch {
            phase = .failed
            lastError = String(describing: error)
            throw error
        }
    }

    public func approvePermission(
        pendingID: UUID,
        duration: GrantDuration
    ) async throws -> RuntimeOutcome {
        guard let pending = pendingExecutions.removeValue(forKey: pendingID) else {
            throw AgentRuntimeError.pendingPermissionNotFound
        }
        guard let toolRuntime else {
            throw AgentRuntimeError.toolsUnavailable
        }

        do {
            lastError = nil
            _ = await toolRuntime.grant(pending.approval.permission, duration: duration)

            phase = .executingTool
            let outcome = try await toolRuntime.execute(pending.call)

            switch outcome {
            case .permissionRequired(let changedRequest):
                return suspendForPermission(
                    conversation: pending.conversation,
                    conversationID: pending.conversationID,
                    call: pending.call,
                    request: changedRequest,
                    completedToolSteps: pending.completedToolSteps,
                    contextSnapshot: pending.contextSnapshot,
                    transientToolEvents: pending.transientToolEvents
                )

            case .success(let success):
                let persisted = try await persistToolSuccess(
                    success,
                    call: pending.call,
                    in: pending.conversation
                )
                var transient = pending.transientToolEvents
                transient[pending.call.id] = persisted.transientEvent
                return try await continueRun(
                    conversation: persisted.conversation,
                    conversationID: pending.conversationID,
                    completedToolSteps: pending.completedToolSteps + 1,
                    contextSnapshot: pending.contextSnapshot,
                    transientToolEvents: transient
                )
            }
        } catch {
            phase = .failed
            lastError = String(describing: error)
            throw error
        }
    }

    public func denyPermission(pendingID: UUID) async throws -> RuntimeOutcome {
        guard let pending = pendingExecutions.removeValue(forKey: pendingID) else {
            throw AgentRuntimeError.pendingPermissionNotFound
        }

        do {
            lastError = nil
            let persisted = try await persistToolDenial(
                call: pending.call,
                request: pending.approval.permission,
                in: pending.conversation
            )
            var transient = pending.transientToolEvents
            transient[pending.call.id] = persisted.transientEvent

            return try await continueRun(
                conversation: persisted.conversation,
                conversationID: pending.conversationID,
                completedToolSteps: pending.completedToolSteps + 1,
                contextSnapshot: pending.contextSnapshot,
                transientToolEvents: transient
            )
        } catch {
            phase = .failed
            lastError = String(describing: error)
            throw error
        }
    }

    public func loadConversation(id: UUID) async throws -> Conversation? {
        phase = .loadingConversation
        defer {
            phase = hasPendingExecution(for: id) ? .awaitingPermission : .idle
        }
        return try await store.loadConversation(id: id)
    }

    private func continueRun(
        conversation: Conversation,
        conversationID: UUID,
        completedToolSteps: Int,
        contextSnapshot: ModelContextSnapshot?,
        transientToolEvents: [UUID: ToolHistoryEvent]
    ) async throws -> RuntimeOutcome {
        phase = .waitingForModel

        let tools: [ToolDescriptor]
        if let toolRuntime {
            tools = await toolRuntime.descriptors()
        } else {
            tools = []
        }

        let visibleMessages = try modelMessages(
            from: conversation.messages,
            transientToolEvents: transientToolEvents
        )
        let turn = try await model.respond(
            to: ModelRequest(
                messages: visibleMessages,
                availableTools: tools,
                contextSnapshot: contextSnapshot
            )
        )

        switch turn {
        case .final(let content):
            let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw AgentRuntimeError.emptyFinalResponse
            }

            let citations = try GroundedCitationResolver().resolve(
                in: normalized,
                context: contextSnapshot?.groundedKnowledge
            )

            var updated = conversation
            let assistantMessage = ChatMessage(role: .assistant, content: normalized)
            updated.messages.append(assistantMessage)
            updated.updatedAt = Date()

            phase = .persistingAssistantMessage
            try await store.saveConversation(updated)
            phase = .idle

            return .completed(
                RuntimeResponse(
                    conversation: updated,
                    assistantMessage: assistantMessage,
                    citations: citations
                )
            )

        case .toolCall(let call):
            guard completedToolSteps < maxToolSteps else {
                throw AgentRuntimeError.toolStepLimitExceeded(maxToolSteps)
            }
            guard let toolRuntime else {
                throw AgentRuntimeError.toolsUnavailable
            }

            phase = .executingTool
            let outcome = try await toolRuntime.execute(call)
            switch outcome {
            case .permissionRequired(let request):
                return suspendForPermission(
                    conversation: conversation,
                    conversationID: conversationID,
                    call: call,
                    request: request,
                    completedToolSteps: completedToolSteps,
                    contextSnapshot: contextSnapshot,
                    transientToolEvents: transientToolEvents
                )

            case .success(let success):
                let persisted = try await persistToolSuccess(
                    success,
                    call: call,
                    in: conversation
                )
                var transient = transientToolEvents
                transient[call.id] = persisted.transientEvent
                return try await continueRun(
                    conversation: persisted.conversation,
                    conversationID: conversationID,
                    completedToolSteps: completedToolSteps + 1,
                    contextSnapshot: contextSnapshot,
                    transientToolEvents: transient
                )
            }
        }
    }

    private func suspendForPermission(
        conversation: Conversation,
        conversationID: UUID,
        call: ToolCall,
        request: PermissionRequest,
        completedToolSteps: Int,
        contextSnapshot: ModelContextSnapshot?,
        transientToolEvents: [UUID: ToolHistoryEvent]
    ) -> RuntimeOutcome {
        let pendingID = UUID()
        let approval = PendingToolApproval(
            id: pendingID,
            conversation: conversation,
            permission: request,
            toolName: call.name,
            toolVersion: call.version
        )

        pendingExecutions[pendingID] = PendingExecution(
            approval: approval,
            conversationID: conversationID,
            conversation: conversation,
            call: call,
            completedToolSteps: completedToolSteps,
            contextSnapshot: contextSnapshot,
            transientToolEvents: transientToolEvents
        )
        phase = .awaitingPermission
        return .permissionRequired(approval)
    }

    private func persistToolSuccess(
        _ success: ToolExecutionSuccess,
        call: ToolCall,
        in conversation: Conversation
    ) async throws -> PersistedToolEvent {
        let durableArguments = try await durableHistoryArguments(for: call)
        let transientArguments = try decodeToolArguments(call.arguments)

        let durableEvent = ToolHistoryEvent(
            status: .success,
            callID: call.id,
            providerCallID: call.providerCallID,
            tool: success.descriptor.name,
            version: success.descriptor.version,
            arguments: durableArguments,
            data: success.historyData,
            warnings: success.warnings,
            metadata: success.metadata,
            detail: nil
        )
        let transientEvent = ToolHistoryEvent(
            status: .success,
            callID: call.id,
            providerCallID: call.providerCallID,
            tool: success.descriptor.name,
            version: success.descriptor.version,
            arguments: transientArguments,
            data: success.data,
            warnings: success.warnings,
            metadata: success.metadata,
            detail: nil
        )
        let updated = try await appendToolEvent(durableEvent, to: conversation)
        return PersistedToolEvent(conversation: updated, transientEvent: transientEvent)
    }

    private func persistToolDenial(
        call: ToolCall,
        request: PermissionRequest,
        in conversation: Conversation
    ) async throws -> PersistedToolEvent {
        let detail = "User denied \(request.capability.rawValue) for \(request.resource.identifier)."
        let durableEvent = ToolHistoryEvent(
            status: .denied,
            callID: call.id,
            providerCallID: call.providerCallID,
            tool: call.name,
            version: call.version,
            arguments: try await durableHistoryArguments(for: call),
            data: nil,
            warnings: [],
            metadata: [:],
            detail: detail
        )
        let transientEvent = ToolHistoryEvent(
            status: .denied,
            callID: call.id,
            providerCallID: call.providerCallID,
            tool: call.name,
            version: call.version,
            arguments: try decodeToolArguments(call.arguments),
            data: nil,
            warnings: [],
            metadata: [:],
            detail: detail
        )
        let updated = try await appendToolEvent(durableEvent, to: conversation)
        return PersistedToolEvent(conversation: updated, transientEvent: transientEvent)
    }

    private func modelMessages(
        from durableMessages: [ChatMessage],
        transientToolEvents: [UUID: ToolHistoryEvent]
    ) throws -> [ChatMessage] {
        guard !transientToolEvents.isEmpty else { return durableMessages }

        return try durableMessages.map { message in
            guard
                message.role == .tool,
                let data = message.content.data(using: .utf8),
                let durableEvent = try? JSONDecoder().decode(ToolHistoryEvent.self, from: data),
                let transientEvent = transientToolEvents[durableEvent.callID]
            else {
                return message
            }

            let transientData = try JSONEncoder().encode(transientEvent)
            guard let content = String(data: transientData, encoding: .utf8) else {
                throw AgentRuntimeError.toolEventEncodingFailed
            }
            return ChatMessage(
                id: message.id,
                role: message.role,
                content: content,
                createdAt: message.createdAt
            )
        }
    }

    private func durableHistoryArguments(for call: ToolCall) async throws -> JSONValue {
        if let toolRuntime {
            do {
                return try await toolRuntime.historyArguments(for: call)
            } catch {
                throw AgentRuntimeError.toolArgumentsEncodingFailed
            }
        }
        return try decodeToolArguments(call.arguments)
    }

    private func appendToolEvent(
        _ event: ToolHistoryEvent,
        to conversation: Conversation
    ) async throws -> Conversation {
        let data = try JSONEncoder().encode(event)
        guard let content = String(data: data, encoding: .utf8) else {
            throw AgentRuntimeError.toolEventEncodingFailed
        }

        var updated = conversation
        updated.messages.append(ChatMessage(role: .tool, content: content))
        updated.updatedAt = Date()

        phase = .persistingToolResult
        try await store.saveConversation(updated)
        return updated
    }

    private func decodeToolArguments(_ data: Data) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw AgentRuntimeError.toolArgumentsEncodingFailed
        }
    }

    private func hasPendingExecution(for conversationID: UUID) -> Bool {
        pendingExecutions.values.contains { $0.conversationID == conversationID }
    }

    private static func makeTitle(from text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        if singleLine.count <= 48 { return singleLine }
        return String(singleLine.prefix(45)) + "…"
    }
}

private struct PendingExecution: Sendable {
    let approval: PendingToolApproval
    let conversationID: UUID
    let conversation: Conversation
    let call: ToolCall
    let completedToolSteps: Int
    let contextSnapshot: ModelContextSnapshot?
    let transientToolEvents: [UUID: ToolHistoryEvent]
}

private struct PersistedToolEvent: Sendable {
    let conversation: Conversation
    let transientEvent: ToolHistoryEvent
}

public enum AgentRuntimeError: Error, CustomStringConvertible, Sendable {
    case emptyInput
    case emptyFinalResponse
    case pendingPermissionExists
    case pendingPermissionNotFound
    case toolsUnavailable
    case toolStepLimitExceeded(Int)
    case toolEventEncodingFailed
    case toolArgumentsEncodingFailed

    public var description: String {
        switch self {
        case .emptyInput:
            return "Message cannot be empty."
        case .emptyFinalResponse:
            return "Model returned an empty final response."
        case .pendingPermissionExists:
            return "This conversation is waiting for an explicit permission decision."
        case .pendingPermissionNotFound:
            return "The pending permission request no longer exists."
        case .toolsUnavailable:
            return "The model requested a tool, but ToolRuntime is unavailable."
        case .toolStepLimitExceeded(let limit):
            return "Tool step limit exceeded (\(limit))."
        case .toolEventEncodingFailed:
            return "Tool event could not be encoded for durable conversation history."
        case .toolArgumentsEncodingFailed:
            return "Tool arguments could not be encoded for durable protocol history."
        }
    }
}
