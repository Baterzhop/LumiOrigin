import Foundation
import XCTest
@testable import LumiCore

final class MemoryToolTests: XCTestCase {
    func testRememberRequiresExplicitApprovalAndMemorySessionGrantIsDowngradedToOnce() async throws {
        let fixture = try MemoryToolFixture()
        defer { fixture.cleanup() }

        let call = try ToolCall.encoding(
            name: "memory.remember",
            version: "1",
            input: RememberMemoryInput(
                key: "profile.preferred.language",
                kind: .preference,
                value: "Ukrainian",
                confidence: 1.0
            )
        )

        let first = try await fixture.runtime.execute(call)
        guard case .permissionRequired(let request) = first else {
            return XCTFail("Persistent memory must pause before mutation")
        }
        XCTAssertEqual(request.capability, .writeUserMemory)
        XCTAssertEqual(request.resource, .userMemory("profile.preferred.language"))
        XCTAssertTrue(request.reason.contains("Ukrainian"))

        let before = try await fixture.service.load(key: "profile.preferred.language")
        XCTAssertNil(before)

        let grant = await fixture.runtime.grant(request, duration: .session)
        XCTAssertEqual(grant.duration, .once)

        let second = try await fixture.runtime.execute(call)
        guard case .success(let success) = second else {
            return XCTFail("Approved exact operation should execute")
        }
        XCTAssertEqual(success.descriptor.name, "memory.remember")

        let saved = try await fixture.service.load(key: "profile.preferred.language")
        XCTAssertEqual(saved?.value, "Ukrainian")
        XCTAssertEqual(saved?.revision, 1)
        XCTAssertEqual(saved?.provenance.sourceKind, .approvedModelProposal)

        // The forced one-time grant was consumed. The same key is not silently
        // delegated for later model-proposed changes in the session.
        let third = try await fixture.runtime.execute(call)
        guard case .permissionRequired = third else {
            return XCTFail("Memory mutation must require a new approval per operation")
        }
    }

    func testGrantForOneMemoryKeyCannotAuthorizeAnotherKey() async throws {
        let fixture = try MemoryToolFixture()
        defer { fixture.cleanup() }

        let callA = try ToolCall.encoding(
            name: "memory.remember",
            version: "1",
            input: RememberMemoryInput(
                key: "profile.name",
                kind: .profile,
                value: "Alice"
            )
        )
        let callB = try ToolCall.encoding(
            name: "memory.remember",
            version: "1",
            input: RememberMemoryInput(
                key: "profile.city",
                kind: .profile,
                value: "Cologne"
            )
        )

        let first = try await fixture.runtime.execute(callA)
        guard case .permissionRequired(let requestA) = first else {
            return XCTFail("Expected permission request for key A")
        }
        _ = await fixture.runtime.grant(requestA, duration: .once)

        let wrongKey = try await fixture.runtime.execute(callB)
        guard case .permissionRequired(let requestB) = wrongKey else {
            return XCTFail("Grant for key A must not authorize key B")
        }
        XCTAssertEqual(requestB.resource, .userMemory("profile.city"))

        let city = try await fixture.service.load(key: "profile.city")
        XCTAssertNil(city)
    }

    func testApprovedReplacementFailsIfRevisionChangesBeforeExecution() async throws {
        let fixture = try MemoryToolFixture()
        defer { fixture.cleanup() }

        let original = try await fixture.service.remember(
            key: "vehicle.favorite.brand",
            kind: .preference,
            value: "Ducati",
            provenance: MemoryProvenance(sourceKind: .manualUserEntry)
        )

        let replacementCall = try ToolCall.encoding(
            name: "memory.remember",
            version: "1",
            input: RememberMemoryInput(
                key: "vehicle.favorite.brand",
                kind: .preference,
                value: "Porsche",
                confidence: 1.0,
                expectedRevision: original.record.revision
            )
        )

        let pending = try await fixture.runtime.execute(replacementCall)
        guard case .permissionRequired(let request) = pending else {
            return XCTFail("Replacement should require explicit approval")
        }

        _ = try await fixture.service.remember(
            key: "vehicle.favorite.brand",
            kind: .preference,
            value: "BMW",
            provenance: MemoryProvenance(sourceKind: .manualUserEntry),
            expectedRevision: original.record.revision
        )

        _ = await fixture.runtime.grant(request, duration: .once)
        do {
            _ = try await fixture.runtime.execute(replacementCall)
            XCTFail("Stale approved operation must fail after state changes")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(
                error,
                .revisionConflict(
                    key: "vehicle.favorite.brand",
                    expected: 1,
                    actual: 2
                )
            )
        }

        let current = try await fixture.service.load(key: "vehicle.favorite.brand")
        XCTAssertEqual(current?.value, "BMW")
        XCTAssertEqual(current?.revision, 2)
    }

    func testForgetIsSeparatePermissionAndHardDeletesAfterExactRevisionApproval() async throws {
        let fixture = try MemoryToolFixture()
        defer { fixture.cleanup() }

        let created = try await fixture.service.remember(
            key: "temporary.secret",
            kind: .context,
            value: "Remove this",
            provenance: MemoryProvenance(sourceKind: .manualUserEntry)
        )
        let call = try ToolCall.encoding(
            name: "memory.forget",
            version: "1",
            input: ForgetMemoryInput(
                key: "temporary.secret",
                expectedRevision: created.record.revision
            )
        )

        let first = try await fixture.runtime.execute(call)
        guard case .permissionRequired(let request) = first else {
            return XCTFail("Forget must pause before deletion")
        }
        XCTAssertEqual(request.capability, .deleteUserMemory)
        XCTAssertEqual(request.resource, .userMemory("temporary.secret"))

        let stillThere = try await fixture.service.load(key: "temporary.secret")
        XCTAssertNotNil(stillThere)

        let grant = await fixture.runtime.grant(request, duration: .session)
        XCTAssertEqual(grant.duration, .once)
        let second = try await fixture.runtime.execute(call)
        guard case .success = second else {
            return XCTFail("Approved forget should execute")
        }

        let deleted = try await fixture.service.load(key: "temporary.secret")
        XCTAssertNil(deleted)
        let history = try await fixture.store.history(memoryID: created.record.id)
        XCTAssertTrue(history.isEmpty)
    }

    func testModelCannotControlMemoryProvenanceThroughToolArguments() async throws {
        let fixture = try MemoryToolFixture()
        defer { fixture.cleanup() }

        let descriptor = RememberMemoryTool.descriptor
        guard case .object(let schema) = descriptor.inputSchema,
              case .object(let properties)? = schema["properties"] else {
            return XCTFail("Expected object tool schema")
        }
        XCTAssertNil(properties["provenance"])
        XCTAssertNil(properties["sourceKind"])
        XCTAssertNil(properties["conversationID"])
        XCTAssertNil(properties["messageID"])
    }
}

private final class MemoryToolFixture: @unchecked Sendable {
    let directory: URL
    let store: SQLiteMemoryStore
    let service: MemoryService
    let runtime: ToolRuntime

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-memory-tool-tests-\(UUID().uuidString)")
        let databaseURL = directory.appendingPathComponent("memory.sqlite3")
        store = try SQLiteMemoryStore(url: databaseURL)
        service = MemoryService(store: store)
        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [
            AnyTool(RememberMemoryTool(service: service)),
            AnyTool(ForgetMemoryTool(service: service))
        ])
        runtime = ToolRuntime(registry: registry, permissions: permissions)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
