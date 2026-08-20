import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LumiCore

final class NativeAgentToolIntegrationTests: XCTestCase {
    func testNativeProviderStopsForPermissionThenCompletesToolRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiNativeAgent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secret = "NATIVE-INTEGRATION-SECRET"
        let fileURL = directory.appendingPathComponent("fixture.txt")
        try Data(secret.utf8).write(to: fileURL)

        let wireName = ReadTextFileTool.descriptor.wireName
        let escapedPath = fileURL.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let firstResponse = Data(
            """
            {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_integration_1","type":"function","function":{"name":"\(wireName)","arguments":"{\\"path\\":\\"\(escapedPath)\\"}"}}]}}]}
            """.utf8
        )
        let secondResponse = Data(
            #"{"choices":[{"message":{"role":"assistant","content":"File processed safely."}}]}"#.utf8
        )

        let transport = IntegrationHTTPTransport(responses: [
            HTTPTransportResponse(statusCode: 200, data: firstResponse),
            HTTPTransportResponse(statusCode: 200, data: secondResponse)
        ])
        let provider = OpenAICompatibleProvider(
            endpoint: URL(string: "http://127.0.0.1:8080/v1/chat/completions")!,
            model: "integration-model",
            systemPrompt: "Integration test",
            transport: transport
        )
        let store = try SQLiteConversationStore(
            url: directory.appendingPathComponent("lumi.sqlite3")
        )
        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [AnyTool(ReadTextFileTool())])
        let runtime = AgentRuntime(
            store: store,
            model: provider,
            toolRuntime: ToolRuntime(registry: registry, permissions: permissions)
        )
        let conversationID = UUID()

        let first = try await runtime.send(
            "Read the selected text file",
            conversationID: conversationID
        )
        guard case .permissionRequired(let pending) = first else {
            return XCTFail("Native model tool call must suspend for explicit permission")
        }
        XCTAssertEqual(pending.toolName, "file.readText")
        XCTAssertEqual(pending.permission.resource.identifier, fileURL.path)

        let requestsBeforeApproval = await transport.capturedBodies()
        XCTAssertEqual(requestsBeforeApproval.count, 1)
        let firstRequestText = String(data: requestsBeforeApproval[0], encoding: .utf8) ?? ""
        XCTAssertFalse(firstRequestText.contains(secret))

        let approved = try await runtime.approvePermission(
            pendingID: pending.id,
            duration: .once
        )
        guard case .completed(let response) = approved else {
            return XCTFail("Approved native tool call should complete")
        }
        XCTAssertEqual(response.assistantMessage.content, "File processed safely.")

        let allRequests = await transport.capturedBodies()
        XCTAssertEqual(allRequests.count, 2)
        let secondRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: allRequests[1]) as? [String: Any]
        )
        let messages = try XCTUnwrap(secondRoot["messages"] as? [[String: Any]])
        let assistantToolCall = try XCTUnwrap(
            messages.first(where: { ($0["role"] as? String) == "assistant" && $0["tool_calls"] != nil })
        )
        let calls = try XCTUnwrap(assistantToolCall["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, "call_integration_1")

        let toolMessage = try XCTUnwrap(
            messages.first(where: { ($0["role"] as? String) == "tool" })
        )
        XCTAssertEqual(toolMessage["tool_call_id"] as? String, "call_integration_1")
        let toolContent = toolMessage["content"] as? String ?? ""
        XCTAssertTrue(toolContent.contains(secret))

        let restored = try await store.loadConversation(id: conversationID)
        let durableConversation = try XCTUnwrap(restored)
        XCTAssertTrue(durableConversation.messages.contains(where: { $0.role == .tool }))
        XCTAssertEqual(durableConversation.messages.last?.role, .assistant)
    }
}

private actor IntegrationHTTPTransport: HTTPTransport {
    private var responses: [HTTPTransportResponse]
    private var requestBodies: [Data] = []

    init(responses: [HTTPTransportResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        requestBodies.append(request.httpBody ?? Data())
        guard !responses.isEmpty else {
            throw IntegrationTransportError.noResponse
        }
        return responses.removeFirst()
    }

    func capturedBodies() -> [Data] {
        requestBodies
    }
}

private enum IntegrationTransportError: Error {
    case noResponse
}
