import Foundation
import XCTest
@testable import LumiCore

final class DelimitedSpreadsheetTests: XCTestCase {
    func testCSVPreservesQuotedCommasNewlinesEscapedQuotesAndFormulaLikeText() async throws {
        let broker = TestUserFileBroker()
        let resourceID = broker.register(
            content: "name,note,formula\r\nAlice,\"hello, world\",=SUM(A1:A2)\r\nBob,\"line one\r\nline two and \"\"quoted\"\"\",+1+2\r\n",
            displayName: "people.csv"
        )
        let reader = DelimitedSpreadsheetReader(broker: broker)

        let table = try await reader.read(
            SpreadsheetReadRequest(resourceID: resourceID)
        )

        XCTAssertEqual(table.format, .csv)
        XCTAssertEqual(table.columns.map(\.name), ["name", "note", "formula"])
        XCTAssertEqual(table.rowCount, 2)
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.rows[0].cells[1].rawValue, "hello, world")
        XCTAssertEqual(table.rows[1].cells[1].rawValue, "line one\nline two and \"quoted\"")
        XCTAssertEqual(table.rows[0].cells[2].rawValue, "=SUM(A1:A2)")
        XCTAssertEqual(table.rows[0].cells[2].kind, .text)
        XCTAssertEqual(table.rows[1].cells[2].rawValue, "+1+2")
        XCTAssertEqual(table.fullRange?.stableIdentity, "table:0:r1-2:c1-3")
    }

    func testTSVAutoDelimiterAndNoHeaderUseStableColumnNames() async throws {
        let broker = TestUserFileBroker()
        let resourceID = broker.register(
            content: "00123\ttrue\n00456\tfalse\n",
            displayName: "ids.tsv"
        )
        let reader = DelimitedSpreadsheetReader(broker: broker)

        let table = try await reader.read(
            SpreadsheetReadRequest(
                resourceID: resourceID,
                headerMode: .none
            )
        )

        XCTAssertEqual(table.format, .tsv)
        XCTAssertEqual(table.columns.map(\.name), ["column_1", "column_2"])
        XCTAssertEqual(table.rows[0].cells[0], .losslessDelimitedText("00123"))
        XCTAssertEqual(table.rows[0].cells[1].kind, .text)
    }

    func testRaggedRowsFailExplicitly() async throws {
        let broker = TestUserFileBroker()
        let resourceID = broker.register(
            content: "a,b\n1,2\n3\n",
            displayName: "ragged.csv"
        )
        let reader = DelimitedSpreadsheetReader(broker: broker)

        do {
            _ = try await reader.read(SpreadsheetReadRequest(resourceID: resourceID))
            XCTFail("Ragged rows must not be silently padded")
        } catch let error as SpreadsheetError {
            XCTAssertEqual(
                error,
                .raggedRow(row: 3, expectedColumns: 2, actualColumns: 1)
            )
        }
    }

    func testUnterminatedQuoteFailsExplicitly() async throws {
        let broker = TestUserFileBroker()
        let resourceID = broker.register(
            content: "a,b\n1,\"unterminated\n",
            displayName: "broken.csv"
        )
        let reader = DelimitedSpreadsheetReader(broker: broker)

        do {
            _ = try await reader.read(SpreadsheetReadRequest(resourceID: resourceID))
            XCTFail("Malformed quotes must fail closed")
        } catch let error as SpreadsheetError {
            guard case .malformedDelimitedText(_, _, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("unterminated"))
        }
    }

    func testDuplicateOrEmptyHeaderFailsInsteadOfInventingSchema() async throws {
        let broker = TestUserFileBroker()
        let duplicateID = broker.register(
            content: "Name,name\nA,B\n",
            displayName: "duplicate.csv"
        )
        let emptyID = broker.register(
            content: "name,\nA,B\n",
            displayName: "empty-header.csv"
        )
        let reader = DelimitedSpreadsheetReader(broker: broker)

        do {
            _ = try await reader.read(SpreadsheetReadRequest(resourceID: duplicateID))
            XCTFail("Duplicate headers should be rejected")
        } catch let error as SpreadsheetError {
            guard case .invalidHeader(let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("duplicate"))
        }

        do {
            _ = try await reader.read(SpreadsheetReadRequest(resourceID: emptyID))
            XCTFail("Empty header names should be rejected")
        } catch let error as SpreadsheetError {
            guard case .invalidHeader(let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("empty"))
        }
    }

    func testByteAndRowLimitsFailRatherThanParsingPartialData() async throws {
        let broker = TestUserFileBroker()
        let resourceID = broker.register(
            content: "a,b\n1,2\n3,4\n",
            displayName: "bounded.csv"
        )
        let reader = DelimitedSpreadsheetReader(broker: broker)

        do {
            _ = try await reader.read(
                SpreadsheetReadRequest(resourceID: resourceID, maxBytes: 5)
            )
            XCTFail("A truncated broker read must never be parsed as a complete table")
        } catch let error as SpreadsheetError {
            XCTAssertEqual(error, .inputTooLarge(maxBytes: 5))
        }

        do {
            _ = try await reader.read(
                SpreadsheetReadRequest(resourceID: resourceID, maxRows: 1)
            )
            XCTFail("Rows beyond the configured bound must fail explicitly")
        } catch let error as SpreadsheetError {
            // first-row header permits one additional raw record; the third
            // record proves there is more than one configured data row.
            XCTAssertEqual(error, .rowLimitExceeded(maxRows: 2))
        }
    }

    func testInspectInputDecodesSafeDefaultsWhenModelOnlySendsResourceID() throws {
        let id = UserFileResourceID(rawValue: "opaque-table")
        let data = Data("{\"resourceID\":\"opaque-table\"}".utf8)
        let input = try JSONDecoder().decode(SpreadsheetInspectInput.self, from: data)

        XCTAssertEqual(input.resourceID, id)
        XCTAssertEqual(input.headerMode, .firstRow)
        XCTAssertEqual(input.delimiter, .auto)
        XCTAssertEqual(input.maxBytes, SpreadsheetInspectInput.defaultMaxBytes)
        XCTAssertEqual(input.maxRows, SpreadsheetInspectInput.defaultMaxRows)
        XCTAssertEqual(input.maxColumns, SpreadsheetInspectInput.defaultMaxColumns)
        XCTAssertEqual(input.previewRows, SpreadsheetInspectInput.defaultPreviewRows)
    }

    func testInspectToolUsesOpaqueResourcePermissionAndReturnsBoundedPreview() async throws {
        let broker = TestUserFileBroker()
        let resourceID = broker.register(
            content: "name,value\nA,1\nB,2\nC,3\n",
            displayName: "table.csv"
        )
        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [
            AnyTool(SpreadsheetInspectTool(broker: broker))
        ])
        let runtime = ToolRuntime(registry: registry, permissions: permissions)
        let call = try ToolCall.encoding(
            name: "spreadsheet.inspect",
            version: "1",
            input: SpreadsheetInspectInput(
                resourceID: resourceID,
                previewRows: 2
            )
        )

        let first = try await runtime.execute(call)
        guard case .permissionRequired(let request) = first else {
            return XCTFail("Spreadsheet read must require the selected-resource permission")
        }
        XCTAssertEqual(request.capability, .readUserFile)
        XCTAssertEqual(request.resource, .userFile(resourceID))
        XCTAssertEqual(request.resourceDisplayName, "table.csv")

        _ = await runtime.grant(request, duration: .once)
        let second = try await runtime.execute(call)
        guard case .success(let success) = second else {
            return XCTFail("Approved spreadsheet inspection should execute")
        }

        let encoded = try JSONEncoder().encode(success.data)
        let output = try JSONDecoder().decode(SpreadsheetInspectOutput.self, from: encoded)
        XCTAssertEqual(output.rowCount, 3)
        XCTAssertEqual(output.columnCount, 2)
        XCTAssertEqual(output.preview.count, 2)
        XCTAssertTrue(output.previewTruncated)
        XCTAssertEqual(output.preview[0].values, ["A", "1"])
    }

    func testUnknownOpaqueResourceFailsBeforePermissionPrompt() async throws {
        let broker = TestUserFileBroker()
        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [
            AnyTool(SpreadsheetInspectTool(broker: broker))
        ])
        let runtime = ToolRuntime(registry: registry, permissions: permissions)
        let call = try ToolCall.encoding(
            name: "spreadsheet.inspect",
            version: "1",
            input: SpreadsheetInspectInput(
                resourceID: UserFileResourceID(rawValue: "/tmp/invented.csv")
            )
        )

        do {
            _ = try await runtime.execute(call)
            XCTFail("A model-invented resource identifier must fail before approval")
        } catch let error as ToolRuntimeError {
            guard case .invalidArguments(let tool, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(tool, "spreadsheet.inspect@1")
        }
    }
}
