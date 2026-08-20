import Foundation
import XCTest
@testable import LumiCore

final class SpreadsheetProfileTests: XCTestCase {
    func testProfileReturnsDeterministicAggregatesWithoutRawRows() async throws {
        let broker = TestUserFileBroker()
        let resourceID = broker.register(
            content: "name,score,active\nAlice,10,true\nBob,20,false\nAlice,,true\nCarol,30,\n",
            displayName: "scores.csv"
        )
        let tool = SpreadsheetProfileTool(broker: broker)

        let output = try await tool.execute(
            SpreadsheetProfileInput(resourceID: resourceID)
        )

        XCTAssertEqual(output.rowCount, 4)
        XCTAssertEqual(output.columnCount, 3)

        let name = output.columns[0]
        XCTAssertEqual(name.name, "name")
        XCTAssertEqual(name.emptyCount, 0)
        XCTAssertEqual(name.nonEmptyCount, 4)
        XCTAssertEqual(name.distinctNonEmptyCount, 3)
        XCTAssertEqual(name.numericCount, 0)
        XCTAssertNil(name.numeric)

        let score = output.columns[1]
        XCTAssertEqual(score.emptyCount, 1)
        XCTAssertEqual(score.numericCount, 3)
        XCTAssertEqual(score.numeric?.minimum, 10)
        XCTAssertEqual(score.numeric?.maximum, 30)
        XCTAssertEqual(score.numeric?.mean, 20)

        let active = output.columns[2]
        XCTAssertEqual(active.emptyCount, 1)
        XCTAssertEqual(active.booleanLiteralCount, 3)
        XCTAssertEqual(active.distinctNonEmptyCount, 2)

        let encoded = try JSONEncoder().encode(output)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("Alice"))
        XCTAssertFalse(json.contains("Carol"))
    }

    func testProfileKeepsLeadingZeroIdentifiersOutOfNumericMutationSemantics() async throws {
        let broker = TestUserFileBroker()
        let resourceID = broker.register(
            content: "id\n00123\n00456\n",
            displayName: "ids.csv"
        )
        let reader = DelimitedSpreadsheetReader(broker: broker)
        let table = try await reader.read(SpreadsheetReadRequest(resourceID: resourceID))
        let tool = SpreadsheetProfileTool(reader: reader, broker: broker)
        let profile = try await tool.execute(SpreadsheetProfileInput(resourceID: resourceID))

        XCTAssertEqual(table.rows[0].cells[0].kind, .text)
        XCTAssertEqual(table.rows[0].cells[0].rawValue, "00123")
        // Profile may report that values are parseable numerically, but the table
        // source representation remains text and is never rewritten/inferred.
        XCTAssertEqual(profile.columns[0].numericCount, 2)
    }

    func testProfileToolUsesSameOpaqueReadPermissionBoundary() async throws {
        let broker = TestUserFileBroker()
        let resourceID = broker.register(
            content: "name,value\nA,1\n",
            displayName: "profile.csv"
        )
        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [
            AnyTool(SpreadsheetProfileTool(broker: broker))
        ])
        let runtime = ToolRuntime(registry: registry, permissions: permissions)
        let call = try ToolCall.encoding(
            name: "spreadsheet.profile",
            version: "1",
            input: SpreadsheetProfileInput(resourceID: resourceID)
        )

        let first = try await runtime.execute(call)
        guard case .permissionRequired(let request) = first else {
            return XCTFail("Profile must require read access to the exact selected resource")
        }
        XCTAssertEqual(request.resource, .userFile(resourceID))
        XCTAssertEqual(request.capability, .readUserFile)

        _ = await runtime.grant(request, duration: .once)
        let second = try await runtime.execute(call)
        guard case .success(let success) = second else {
            return XCTFail("Approved profile should execute")
        }
        XCTAssertEqual(success.descriptor.name, "spreadsheet.profile")
    }
}
