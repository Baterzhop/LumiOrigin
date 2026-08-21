import Foundation
import XCTest
@testable import LumiCore

final class SpreadsheetAgentRuntimeTests: XCTestCase {
    func testGolden006PreviewApprovalWriteApprovalAndFinalResponse() async throws {
        let broker = TestUserFileBroker()
        let secretFormula = "=PRIVATE-CELL+1"
        let sourceID = broker.register(
            content: "name,value\nAlice,\(secretFormula)\nBob,2\n",
            displayName: "source.csv"
        )
        let outputID = broker.register(
            content: "",
            displayName: "safe-output.csv",
            locationHint: "/user-selected/safe-output.csv"
        )
        let plans = SpreadsheetMutationPlanStore()
        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [
            AnyTool(SpreadsheetPreviewMutationTool(
                broker: broker,
                outputBroker: broker,
                plans: plans
            )),
            AnyTool(SpreadsheetWriteMutationTool(
                outputBroker: broker,
                plans: plans
            ))
        ])
        let tools = ToolRuntime(registry: registry, permissions: permissions)
        let model = SpreadsheetWriteFlowModel(
            sourceID: sourceID,
            outputID: outputID
        )
        let conversations = SpreadsheetWriteConversationStore()
        let runtime = AgentRuntime(
            store: conversations,
            model: model,
            toolRuntime: tools
        )
        let conversationID = UUID()

        let first = try await runtime.send(
            "Create a safe transformed output with name and value.",
            conversationID: conversationID
        )
        guard case .permissionRequired(let readPending) = first else {
            return XCTFail("Preview must first pause for source read permission")
        }
        XCTAssertEqual(readPending.permission.capability, .readUserFile)
        XCTAssertEqual(readPending.permission.resource, .userFile(sourceID))
        XCTAssertEqual(try broker.content(resourceID: outputID), "")

        let afterReadApproval = try await runtime.approvePermission(
            pendingID: readPending.id,
            duration: .once
        )
        guard case .permissionRequired(let writePending) = afterReadApproval else {
            return XCTFail("After preview, runtime must pause separately for output write permission")
        }
        XCTAssertEqual(writePending.permission.capability, .writeUserFile)
        XCTAssertEqual(writePending.permission.resource, .userFile(outputID))
        XCTAssertEqual(writePending.permission.details["sourceResourceID"], sourceID.rawValue)
        XCTAssertEqual(writePending.permission.details["outputResourceID"], outputID.rawValue)
        XCTAssertEqual(writePending.permission.details["overwritePolicy"], "require-empty-output")
        XCTAssertEqual(try broker.content(resourceID: outputID), "")

        let completed = try await runtime.approvePermission(
            pendingID: writePending.id,
            duration: .session
        )
        guard case .completed(let response) = completed else {
            return XCTFail("Exact approved write should complete the agent turn")
        }
        XCTAssertEqual(response.assistantMessage.content, "The previewed output was written safely.")

        let output = try broker.content(resourceID: outputID)
        XCTAssertTrue(output.contains("'=PRIVATE-CELL+1"))
        XCTAssertTrue(output.contains("Bob,2"))

        let maybePlanToken = await model.planToken()
        let capturedPlanToken = try XCTUnwrap(maybePlanToken)
        XCTAssertFalse(capturedPlanToken.isEmpty)

        let durable = try await conversations.loadConversation(id: conversationID)
        let durableText = try XCTUnwrap(durable).messages.map(\.content).joined(separator: "\n")
        XCTAssertFalse(durableText.contains(secretFormula))
        XCTAssertFalse(durableText.contains(capturedPlanToken))
        XCTAssertTrue(durableText.contains("redacted:ephemeral-plan-token"))
        XCTAssertTrue(durableText.contains("redacted:ephemeral-spreadsheet-row-values"))

        _ = try await runtime.send(
            "Give me a short follow-up.",
            conversationID: conversationID
        )
        let requests = await model.requests()
        XCTAssertEqual(requests.count, 4)
        let nextTurnHistory = requests[3].messages.map(\.content).joined(separator: "\n")
        XCTAssertFalse(nextTurnHistory.contains(secretFormula))
        XCTAssertFalse(nextTurnHistory.contains(capturedPlanToken))
    }
}

private actor SpreadsheetWriteFlowModel: ModelProvider {
    private let sourceID: UserFileResourceID
    private let outputID: UserFileResourceID
    private var step = 0
    private var capturedRequests: [ModelRequest] = []
    private var capturedPlanToken: String?

    init(sourceID: UserFileResourceID, outputID: UserFileResourceID) {
        self.sourceID = sourceID
        self.outputID = outputID
    }

    func respond(to request: ModelRequest) async throws -> ModelTurn {
        capturedRequests.append(request)
        defer { step += 1 }

        switch step {
        case 0:
            return .toolCall(
                try ToolCall.encoding(
                    name: "spreadsheet.previewMutation",
                    version: "1",
                    input: SpreadsheetPreviewMutationInput(
                        sourceResourceID: sourceID,
                        outputResourceID: outputID,
                        transform: SpreadsheetTransformSpec(
                            selectedColumns: ["name", "value"]
                        ),
                        previewRows: 10
                    ),
                    providerCallID: "golden-006-preview"
                )
            )

        case 1:
            let toolMessage = try latestToolMessage(in: request)
            let event = try decodeEvent(toolMessage)
            let data = try unwrap(event.data)
            let preview = try decode(
                SpreadsheetMutationPreviewOutput.self,
                from: data
            )
            capturedPlanToken = preview.planToken
            return .toolCall(
                try ToolCall.encoding(
                    name: "spreadsheet.writeMutation",
                    version: "1",
                    input: SpreadsheetWriteMutationInput(planToken: preview.planToken),
                    providerCallID: "golden-006-write"
                )
            )

        case 2:
            let toolMessage = try latestToolMessage(in: request)
            let event = try decodeEvent(toolMessage)
            guard event.tool == "spreadsheet.writeMutation", event.status == .success else {
                throw SpreadsheetWriteFlowError.unexpectedToolEvent
            }
            return .final("The previewed output was written safely.")

        case 3:
            return .final("Follow-up complete.")

        default:
            throw SpreadsheetWriteFlowError.noTurn
        }
    }

    func requests() -> [ModelRequest] {
        capturedRequests
    }

    func planToken() -> String? {
        capturedPlanToken
    }

    private func latestToolMessage(in request: ModelRequest) throws -> ChatMessage {
        guard let message = request.messages.last(where: { $0.role == .tool }) else {
            throw SpreadsheetWriteFlowError.missingToolMessage
        }
        return message
    }

    private func decodeEvent(_ message: ChatMessage) throws -> ToolHistoryEvent {
        guard let raw = message.content.data(using: .utf8) else {
            throw SpreadsheetWriteFlowError.invalidToolMessage
        }
        return try JSONDecoder().decode(ToolHistoryEvent.self, from: raw)
    }

    private func unwrap(_ value: JSONValue?) throws -> JSONValue {
        guard let value else { throw SpreadsheetWriteFlowError.missingToolData }
        return value
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        let raw = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: raw)
    }
}

private actor SpreadsheetWriteConversationStore: ConversationStore {
    private var conversations: [UUID: Conversation] = [:]

    func loadConversation(id: UUID) async throws -> Conversation? {
        conversations[id]
    }

    func saveConversation(_ conversation: Conversation) async throws {
        conversations[conversation.id] = conversation
    }
}

private enum SpreadsheetWriteFlowError: Error {
    case noTurn
    case missingToolMessage
    case invalidToolMessage
    case missingToolData
    case unexpectedToolEvent
}
