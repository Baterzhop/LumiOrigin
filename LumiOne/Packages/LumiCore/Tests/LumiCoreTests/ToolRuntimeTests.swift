import Foundation
import XCTest
@testable import LumiCore

final class ToolRuntimeTests: XCTestCase {
    func testReadTextFileRequiresExplicitPermission() async throws {
        let broker = TestUserFileBroker()
        let resourceID = broker.register(
            content: "classified",
            displayName: "secret.txt",
            locationHint: "/Users/test/Documents/secret.txt"
        )

        let permissions = PermissionEngine()
        let runtime = try makeRuntime(permissions: permissions, broker: broker)
        let call = try readCall(for: resourceID)

        let first = try await runtime.execute(call)
        guard case .permissionRequired(let request) = first else {
            return XCTFail("File read must require explicit permission")
        }

        XCTAssertEqual(request.capability, .readUserFile)
        XCTAssertEqual(request.resource.kind, .userFile)
        XCTAssertEqual(request.resource.identifier, resourceID.rawValue)
        XCTAssertEqual(request.resourceDisplayName, "secret.txt")
        XCTAssertEqual(request.resourceLocationHint, "/Users/test/Documents/secret.txt")

        _ = await permissions.grant(request, duration: .once)

        let second = try await runtime.execute(call)
        guard case .success(let result) = second else {
            return XCTFail("Explicit grant should authorize the tool")
        }

        guard case .object(let object) = result.data else {
            return XCTFail("Tool output must be structured JSON data")
        }

        XCTAssertEqual(object["content"], .string("classified"))
        XCTAssertEqual(object["resourceID"], .string(resourceID.rawValue))
        XCTAssertEqual(object["displayName"], .string("secret.txt"))
        XCTAssertEqual(object["truncated"], .bool(false))
        XCTAssertEqual(result.descriptor.name, "file.readText")
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.metadata["encoding"], .string("utf-8"))
        XCTAssertEqual(result.metadata["resourceID"], .string(resourceID.rawValue))
        XCTAssertEqual(result.metadata["bytesRead"], .number(10))
        XCTAssertEqual(result.metadata["truncated"], .bool(false))
    }

    func testUnknownResourceIDFailsBeforePermissionPrompt() async throws {
        let broker = TestUserFileBroker()
        let permissions = PermissionEngine()
        let runtime = try makeRuntime(permissions: permissions, broker: broker)
        let unknown = UserFileResourceID(rawValue: "model-invented-resource")
        let call = try readCall(for: unknown)

        do {
            _ = try await runtime.execute(call)
            XCTFail("Unregistered resource IDs must fail closed before authorization")
        } catch let error as ToolRuntimeError {
            XCTAssertTrue(error.description.contains("Unknown user-file resource model-invented-resource."))
        }

        let grants = await permissions.activeGrants()
        XCTAssertTrue(grants.isEmpty)
    }

    func testOneTimeGrantIsConsumed() async throws {
        let broker = TestUserFileBroker()
        let resourceID = broker.register(content: "once")
        let permissions = PermissionEngine()
        let runtime = try makeRuntime(permissions: permissions, broker: broker)
        let call = try readCall(for: resourceID)

        guard case .permissionRequired(let request) = try await runtime.execute(call) else {
            return XCTFail("Initial call should require permission")
        }

        _ = await permissions.grant(request, duration: .once)
        guard case .success = try await runtime.execute(call) else {
            return XCTFail("First execution should use one-time grant")
        }

        guard case .permissionRequired = try await runtime.execute(call) else {
            return XCTFail("One-time grant must be consumed after one execution")
        }
    }

    func testSessionGrantAllowsRepeatedExecution() async throws {
        let broker = TestUserFileBroker()
        let resourceID = broker.register(content: "session")
        let permissions = PermissionEngine()
        let runtime = try makeRuntime(permissions: permissions, broker: broker)
        let call = try readCall(for: resourceID)

        guard case .permissionRequired(let request) = try await runtime.execute(call) else {
            return XCTFail("Initial call should require permission")
        }
        _ = await permissions.grant(request, duration: .session)

        guard case .success = try await runtime.execute(call) else {
            return XCTFail("Session grant should authorize first execution")
        }
        guard case .success = try await runtime.execute(call) else {
            return XCTFail("Session grant should remain active")
        }
    }

    func testGrantForOneFileCannotAuthorizeAnotherFile() async throws {
        let broker = TestUserFileBroker()
        let firstID = broker.register(content: "first", displayName: "first.txt")
        let secondID = broker.register(content: "second", displayName: "second.txt")
        let permissions = PermissionEngine()
        let runtime = try makeRuntime(permissions: permissions, broker: broker)
        let firstCall = try readCall(for: firstID)
        let secondCall = try readCall(for: secondID)

        guard case .permissionRequired(let firstRequest) = try await runtime.execute(firstCall) else {
            return XCTFail("First file should require permission")
        }
        _ = await permissions.grant(firstRequest, duration: .session)

        guard case .success = try await runtime.execute(firstCall) else {
            return XCTFail("Grant should authorize its exact resource")
        }
        guard case .permissionRequired(let secondRequest) = try await runtime.execute(secondCall) else {
            return XCTFail("Grant for file A must not authorize file B")
        }

        XCTAssertNotEqual(firstRequest.resource, secondRequest.resource)
    }

    func testReplacingSameScopeGrantIsDeterministic() async {
        let permissions = PermissionEngine()
        let id = UserFileResourceID(rawValue: "registered-file-1")
        let request = PermissionRequest(
            capability: .readUserFile,
            resource: .userFile(id),
            reason: "test"
        )

        _ = await permissions.grant(request, duration: .once)
        _ = await permissions.grant(request, duration: .session)

        let grants = await permissions.activeGrants()
        XCTAssertEqual(grants.count, 1)
        XCTAssertEqual(grants.first?.duration, .session)

        let firstAuthorization = await permissions.authorize(request)
        let secondAuthorization = await permissions.authorize(request)
        XCTAssertTrue(firstAuthorization)
        XCTAssertTrue(secondAuthorization)
    }

    func testReadTextFileInputUsesSafeDefaultWhenMaxBytesIsOmitted() throws {
        let json = Data(#"{"resourceID":"registered-file-1"}"#.utf8)
        let decoded = try JSONDecoder().decode(ReadTextFileInput.self, from: json)

        XCTAssertEqual(decoded.resourceID.rawValue, "registered-file-1")
        XCTAssertEqual(decoded.maxBytes, ReadTextFileInput.defaultMaxBytes)
    }

    func testResourceIDEncodesAsJSONStringNotObject() throws {
        let input = ReadTextFileInput(
            resourceID: UserFileResourceID(rawValue: "opaque-123")
        )
        let data = try JSONEncoder().encode(input)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["resourceID"] as? String, "opaque-123")
    }

    func testUnknownToolNeverExecutes() async throws {
        let permissions = PermissionEngine()
        let runtime = try makeRuntime(permissions: permissions, broker: TestUserFileBroker())
        let call = ToolCall(name: "system.magic", version: "99", arguments: Data("{}".utf8))

        do {
            _ = try await runtime.execute(call)
            XCTFail("Unknown tool must fail closed")
        } catch let error as ToolRuntimeError {
            XCTAssertEqual(error.description, "Unknown tool system.magic@99.")
        }
    }

    func testPermissionEngineStartsWithNoImplicitGrants() async {
        let permissions = PermissionEngine()
        let grants = await permissions.activeGrants()
        XCTAssertTrue(grants.isEmpty)
    }

    func testUserOrModelTextCannotActAsPermission() async {
        let permissions = PermissionEngine()
        let request = PermissionRequest(
            capability: .readUserFile,
            resource: .userFile(UserFileResourceID(rawValue: "not-authorized")),
            reason: "The user said in chat: yes, read everything"
        )

        let authorized = await permissions.authorize(request)
        let grants = await permissions.activeGrants()
        XCTAssertFalse(authorized)
        XCTAssertTrue(grants.isEmpty)
    }

    func testDuplicateToolRegistrationFailsClosed() throws {
        do {
            _ = try ToolRegistry(tools: [
                AnyTool(ReadTextFileTool()),
                AnyTool(ReadTextFileTool())
            ])
            XCTFail("Duplicate tool name/version must be rejected")
        } catch let error as ToolRuntimeError {
            XCTAssertEqual(error.description, "Tool registry contains duplicate tool file.readText@2.")
        }
    }

    private func makeRuntime(
        permissions: PermissionEngine,
        broker: any UserFileAccessBroker
    ) throws -> ToolRuntime {
        let registry = try ToolRegistry(tools: [AnyTool(ReadTextFileTool(broker: broker))])
        return ToolRuntime(registry: registry, permissions: permissions)
    }

    private func readCall(for id: UserFileResourceID) throws -> ToolCall {
        try ToolCall.encoding(
            name: "file.readText",
            version: "2",
            input: ReadTextFileInput(resourceID: id)
        )
    }
}
