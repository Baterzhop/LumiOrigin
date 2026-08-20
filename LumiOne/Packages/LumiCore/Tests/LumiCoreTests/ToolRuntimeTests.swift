import Foundation
import XCTest
@testable import LumiCore

final class ToolRuntimeTests: XCTestCase {
    func testReadTextFileRequiresExplicitPermission() async throws {
        let fixture = try TextFixture(content: "classified")
        defer { fixture.cleanup() }

        let permissions = PermissionEngine()
        let runtime = try makeRuntime(permissions: permissions)
        let call = try ToolCall.encoding(
            name: "file.readText",
            version: "1",
            input: ReadTextFileInput(path: fixture.fileURL.path)
        )

        let first = try await runtime.execute(call)
        guard case .permissionRequired(let request) = first else {
            return XCTFail("File read must require explicit permission")
        }

        XCTAssertEqual(request.capability, .readUserFile)
        XCTAssertEqual(request.resource.kind, .file)
        XCTAssertEqual(
            request.resource.identifier,
            fixture.fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        )

        _ = await permissions.grant(request, duration: .once)

        let second = try await runtime.execute(call)
        guard case .success(let result) = second else {
            return XCTFail("Explicit grant should authorize the tool")
        }

        guard case .object(let object) = result.data else {
            return XCTFail("Tool output must be structured JSON data")
        }

        XCTAssertEqual(object["content"], .string("classified"))
        XCTAssertEqual(object["truncated"], .bool(false))
        XCTAssertEqual(result.descriptor.name, "file.readText")
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testOneTimeGrantIsConsumed() async throws {
        let fixture = try TextFixture(content: "once")
        defer { fixture.cleanup() }

        let permissions = PermissionEngine()
        let runtime = try makeRuntime(permissions: permissions)
        let call = try readCall(for: fixture.fileURL)

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
        let fixture = try TextFixture(content: "session")
        defer { fixture.cleanup() }

        let permissions = PermissionEngine()
        let runtime = try makeRuntime(permissions: permissions)
        let call = try readCall(for: fixture.fileURL)

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
        let firstFixture = try TextFixture(content: "first")
        let secondFixture = try TextFixture(content: "second")
        defer {
            firstFixture.cleanup()
            secondFixture.cleanup()
        }

        let permissions = PermissionEngine()
        let runtime = try makeRuntime(permissions: permissions)
        let firstCall = try readCall(for: firstFixture.fileURL)
        let secondCall = try readCall(for: secondFixture.fileURL)

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

    func testUnknownToolNeverExecutes() async throws {
        let permissions = PermissionEngine()
        let runtime = try makeRuntime(permissions: permissions)
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

    private func makeRuntime(permissions: PermissionEngine) throws -> ToolRuntime {
        let registry = try ToolRegistry(tools: [AnyTool(ReadTextFileTool())])
        return ToolRuntime(registry: registry, permissions: permissions)
    }

    private func readCall(for url: URL) throws -> ToolCall {
        try ToolCall.encoding(
            name: "file.readText",
            version: "1",
            input: ReadTextFileInput(path: url.path)
        )
    }
}

private final class TextFixture {
    let directoryURL: URL
    let fileURL: URL

    init(content: String) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = directoryURL.appendingPathComponent("fixture.txt")
        try Data(content.utf8).write(to: fileURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
