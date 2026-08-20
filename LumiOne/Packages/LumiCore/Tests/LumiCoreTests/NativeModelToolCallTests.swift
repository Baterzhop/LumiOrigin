import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LumiCore

final class NativeModelToolCallTests: XCTestCase {
    func testProviderSendsToolSchemaAndParsesNativeToolCall() async throws {
        let descriptor = ReadTextFileTool.descriptor
        XCTAssertEqual(descriptor.wireName, "file_readText_v2")

        let response = Data(
            """
            {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_native_123","type":"function","function":{"name":"\(descriptor.wireName)","arguments":"{\\"resourceID\\":\\"selected-file-123\\"}"}}]}}]}
            """.utf8
        )
        let transport = StubHTTPTransport(responses: [
            HTTPTransportResponse(statusCode: 200, data: response)
        ])
        let provider = makeProvider(transport: transport)

        let turn = try await provider.respond(
            to: ModelRequest(
                messages: [ChatMessage(role: .user, content: "Read the file")],
                availableTools: [descriptor]
            )
        )

        guard case .toolCall(let call) = turn else {
            return XCTFail("Expected a native tool call")
        }
        XCTAssertEqual(call.providerCallID, "call_native_123")
        XCTAssertEqual(call.name, "file.readText")
        XCTAssertEqual(call.version, "2")

        let decodedInput = try JSONDecoder().decode(ReadTextFileInput.self, from: call.arguments)
        XCTAssertEqual(decodedInput.resourceID.rawValue, "selected-file-123")
        XCTAssertEqual(decodedInput.maxBytes, ReadTextFileInput.defaultMaxBytes)

        let bodies = await transport.capturedBodies()
        XCTAssertEqual(bodies.count, 1)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any]
        )
        let tools = try XCTUnwrap(root["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "file_readText_v2")

        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["type"] as? String, "object")
        let required = try XCTUnwrap(parameters["required"] as? [String])
        XCTAssertEqual(required, ["resourceID"])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        XCTAssertNotNil(properties["resourceID"])
        XCTAssertNil(properties["path"])
        XCTAssertNotNil(properties["maxBytes"])
    }

    func testFinalTextResponseStillWorks() async throws {
        let transport = StubHTTPTransport(responses: [
            HTTPTransportResponse(
                statusCode: 200,
                data: Data(#"{"choices":[{"message":{"role":"assistant","content":"  hello  "}}]}"#.utf8)
            )
        ])
        let provider = makeProvider(transport: transport)

        let turn = try await provider.respond(
            to: ModelRequest(messages: [ChatMessage(role: .user, content: "Hi")])
        )

        guard case .final(let text) = turn else {
            return XCTFail("Expected final text")
        }
        XCTAssertEqual(text, "hello")
    }

    func testUnknownReturnedFunctionFailsClosed() async throws {
        let response = Data(
            #"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"system_magic_v1","arguments":"{}"}}]}}]}"#.utf8
        )
        let transport = StubHTTPTransport(responses: [
            HTTPTransportResponse(statusCode: 200, data: response)
        ])
        let provider = makeProvider(transport: transport)

        do {
            _ = try await provider.respond(
                to: ModelRequest(
                    messages: [ChatMessage(role: .user, content: "Do something")],
                    availableTools: [ReadTextFileTool.descriptor]
                )
            )
            XCTFail("Unknown model function must fail closed")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error.description, "Model requested unknown function system_magic_v1.")
        }
    }

    func testMalformedToolArgumentsFailClosed() async throws {
        let wireName = ReadTextFileTool.descriptor.wireName
        let response = Data(
            """
            {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_bad","type":"function","function":{"name":"\(wireName)","arguments":"not-json"}}]}}]}
            """.utf8
        )
        let transport = StubHTTPTransport(responses: [
            HTTPTransportResponse(statusCode: 200, data: response)
        ])
        let provider = makeProvider(transport: transport)

        do {
            _ = try await provider.respond(
                to: ModelRequest(
                    messages: [ChatMessage(role: .user, content: "Read")],
                    availableTools: [ReadTextFileTool.descriptor]
                )
            )
            XCTFail("Malformed tool arguments must fail closed")
        } catch let error as ModelProviderError {
            XCTAssertEqual(
                error.description,
                "Model returned malformed JSON arguments for file.readText@2."
            )
        }
    }

    func testMultipleToolCallsAreRejectedForDeterministicSlice() async throws {
        let wireName = ReadTextFileTool.descriptor.wireName
        let response = Data(
            """
            {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
              {"id":"call_1","type":"function","function":{"name":"\(wireName)","arguments":"{\\"resourceID\\":\\"a\\"}"}},
              {"id":"call_2","type":"function","function":{"name":"\(wireName)","arguments":"{\\"resourceID\\":\\"b\\"}"}}
            ]}}]}
            """.utf8
        )
        let transport = StubHTTPTransport(responses: [
            HTTPTransportResponse(statusCode: 200, data: response)
        ])
        let provider = makeProvider(transport: transport)

        do {
            _ = try await provider.respond(
                to: ModelRequest(
                    messages: [ChatMessage(role: .user, content: "Read two")],
                    availableTools: [ReadTextFileTool.descriptor]
                )
            )
            XCTFail("Multiple calls must be rejected in the deterministic first slice")
        } catch let error as ModelProviderError {
            XCTAssertEqual(
                error.description,
                "Model returned 2 tool calls in one turn; Lumi One currently permits one deterministic tool call per turn."
            )
        }
    }

    func testToolHistoryRoundTripsWithOriginalProviderCallID() async throws {
        let event = ToolHistoryEvent(
            status: .success,
            callID: UUID(),
            providerCallID: "call_roundtrip_42",
            tool: "file.readText",
            version: "2",
            arguments: .object(["resourceID": .string("selected-file-123")]),
            data: .object(["content": .string("safe result")]),
            warnings: [],
            metadata: ["encoding": .string("utf-8")]
        )
        let eventData = try JSONEncoder().encode(event)
        let eventText = try XCTUnwrap(String(data: eventData, encoding: .utf8))

        let transport = StubHTTPTransport(responses: [
            HTTPTransportResponse(
                statusCode: 200,
                data: Data(#"{"choices":[{"message":{"role":"assistant","content":"done"}}]}"#.utf8)
            )
        ])
        let provider = makeProvider(transport: transport)

        _ = try await provider.respond(
            to: ModelRequest(
                messages: [
                    ChatMessage(role: .user, content: "Read it"),
                    ChatMessage(role: .tool, content: eventText)
                ],
                availableTools: [ReadTextFileTool.descriptor]
            )
        )

        let bodies = await transport.capturedBodies()
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any]
        )
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool"])

        let assistant = messages[2]
        let calls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls[0]["id"] as? String, "call_roundtrip_42")
        let function = try XCTUnwrap(calls[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "file_readText_v2")
        let argumentString = try XCTUnwrap(function["arguments"] as? String)
        let argumentData = try XCTUnwrap(argumentString.data(using: .utf8))
        let arguments = try JSONDecoder().decode(JSONValue.self, from: argumentData)
        XCTAssertEqual(arguments, .object(["resourceID": .string("selected-file-123")]))

        let toolMessage = messages[3]
        XCTAssertEqual(toolMessage["tool_call_id"] as? String, "call_roundtrip_42")
        XCTAssertEqual(toolMessage["content"] as? String, eventText)
    }

    func testDuplicateWireNamesFailBeforeHTTP() async throws {
        let first = ToolDescriptor(
            name: "a.b",
            version: "1",
            summary: "first",
            risk: .readOnly,
            capability: .readAppData
        )
        let second = ToolDescriptor(
            name: "a_b",
            version: "1",
            summary: "second",
            risk: .readOnly,
            capability: .readAppData
        )
        XCTAssertEqual(first.wireName, second.wireName)

        let transport = StubHTTPTransport(responses: [])
        let provider = makeProvider(transport: transport)

        do {
            _ = try await provider.respond(
                to: ModelRequest(
                    messages: [ChatMessage(role: .user, content: "test")],
                    availableTools: [first, second]
                )
            )
            XCTFail("Wire-name collision must fail before HTTP")
        } catch let error as ModelProviderError {
            XCTAssertEqual(
                error.description,
                "Multiple Lumi tools map to the same model function name a_b_v1."
            )
        }

        let bodies = await transport.capturedBodies()
        XCTAssertTrue(bodies.isEmpty)
    }

    private func makeProvider(transport: StubHTTPTransport) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            endpoint: URL(string: "http://127.0.0.1:8080/v1/chat/completions")!,
            model: "test-model",
            systemPrompt: "Test system",
            transport: transport
        )
    }
}

private actor StubHTTPTransport: HTTPTransport {
    private var responses: [HTTPTransportResponse]
    private var bodies: [Data] = []

    init(responses: [HTTPTransportResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        bodies.append(request.httpBody ?? Data())
        guard !responses.isEmpty else {
            throw StubTransportError.noResponse
        }
        return responses.removeFirst()
    }

    func capturedBodies() -> [Data] {
        bodies
    }
}

private enum StubTransportError: Error {
    case noResponse
}
