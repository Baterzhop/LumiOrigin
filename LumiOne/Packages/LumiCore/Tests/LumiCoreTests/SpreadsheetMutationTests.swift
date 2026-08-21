import Foundation
import XCTest
@testable import LumiCore

final class SpreadsheetMutationTests: XCTestCase {
    func testTransformSelectFilterAndStableNumericSortAreDeterministic() async throws {
        let broker = TestUserFileBroker()
        let sourceID = broker.register(
            content: "name,age,city\nAlice,30,Berlin\nBob,40,berlin\nCara,40,Hamburg\nDan,40,Berlin\n",
            displayName: "people.csv"
        )
        let source = try await DelimitedSpreadsheetReader(broker: broker).read(
            SpreadsheetReadRequest(resourceID: sourceID)
        )

        let result = try SpreadsheetTransformEngine().apply(
            SpreadsheetTransformSpec(
                selectedColumns: ["name", "age"],
                filter: SpreadsheetFilterSpec(
                    column: "city",
                    operation: .equals,
                    value: "BERLIN",
                    caseSensitive: false
                ),
                sort: SpreadsheetSortSpec(
                    column: "age",
                    direction: .descending,
                    mode: .numeric
                )
            ),
            to: source
        )

        XCTAssertEqual(result.snapshot.columns.map(\.name), ["name", "age"])
        XCTAssertEqual(result.snapshot.rows.map { $0.cells[0].rawValue }, ["Bob", "Dan", "Alice"])
        XCTAssertEqual(result.sourceRowIndices, [2, 4, 1])
        XCTAssertEqual(result.snapshot.rows.map(\.index), [1, 2, 3])
    }

    func testQueryReturnsEphemeralRowsButRedactsDurableHistoryOutput() async throws {
        let broker = TestUserFileBroker()
        let sourceID = broker.register(
            content: "name,secret\nAlice,TOP-SECRET-CELL\n",
            displayName: "private.csv"
        )
        let permissions = PermissionEngine()
        let registry = try ToolRegistry(tools: [
            AnyTool(SpreadsheetQueryTool(broker: broker))
        ])
        let runtime = ToolRuntime(registry: registry, permissions: permissions)
        let call = try ToolCall.encoding(
            name: "spreadsheet.query",
            version: "1",
            input: SpreadsheetQueryInput(resourceID: sourceID)
        )

        let first = try await runtime.execute(call)
        guard case .permissionRequired(let request) = first else {
            return XCTFail("Query must require exact source read permission")
        }
        _ = await runtime.grant(request, duration: .once)

        let second = try await runtime.execute(call)
        guard case .success(let success) = second else {
            return XCTFail("Approved query should execute")
        }

        let ephemeral = String(
            data: try JSONEncoder().encode(success.data),
            encoding: .utf8
        ) ?? ""
        let durable = String(
            data: try JSONEncoder().encode(success.historyData),
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(ephemeral.contains("TOP-SECRET-CELL"))
        XCTAssertFalse(durable.contains("TOP-SECRET-CELL"))
        XCTAssertTrue(durable.contains("redacted:ephemeral-spreadsheet-row-values"))
    }

    func testPreviewThenWriteUsesOneTimeExactPlanAndNeutralizesFormulaInjection() async throws {
        let broker = TestUserFileBroker()
        let sourceID = broker.register(
            content: "name,formula\nA,=1+1\nB,-5\nC,@SUM(A1)\n",
            displayName: "source.csv"
        )
        let outputID = broker.register(
            content: "",
            displayName: "safe-output.csv",
            locationHint: "/user-selected/safe-output.csv"
        )
        let originalSource = try broker.content(resourceID: sourceID)
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
        let runtime = ToolRuntime(registry: registry, permissions: permissions)

        let previewCall = try ToolCall.encoding(
            name: "spreadsheet.previewMutation",
            version: "1",
            input: SpreadsheetPreviewMutationInput(
                sourceResourceID: sourceID,
                outputResourceID: outputID,
                transform: SpreadsheetTransformSpec(selectedColumns: ["name", "formula"])
            )
        )

        let previewPending = try await runtime.execute(previewCall)
        guard case .permissionRequired(let readRequest) = previewPending else {
            return XCTFail("Mutation preview must require source read permission")
        }
        _ = await runtime.grant(readRequest, duration: .once)
        let previewOutcome = try await runtime.execute(previewCall)
        guard case .success(let previewSuccess) = previewOutcome else {
            return XCTFail("Approved preview should execute")
        }
        let previewData = try JSONEncoder().encode(previewSuccess.data)
        let preview = try JSONDecoder().decode(
            SpreadsheetMutationPreviewOutput.self,
            from: previewData
        )
        XCTAssertEqual(preview.rowCount, 3)
        XCTAssertEqual(preview.outputResourceID, outputID)

        let writeCall = try ToolCall.encoding(
            name: "spreadsheet.writeMutation",
            version: "1",
            input: SpreadsheetWriteMutationInput(planToken: preview.planToken)
        )
        let pendingWrite = try await runtime.execute(writeCall)
        guard case .permissionRequired(let writeRequest) = pendingWrite else {
            return XCTFail("Write must pause for explicit approval")
        }
        XCTAssertEqual(writeRequest.capability, .writeUserFile)
        XCTAssertEqual(writeRequest.resource, .userFile(outputID))
        XCTAssertEqual(writeRequest.details["sourceResourceID"], sourceID.rawValue)
        XCTAssertEqual(writeRequest.details["outputResourceID"], outputID.rawValue)
        XCTAssertEqual(writeRequest.details["overwritePolicy"], "require-empty-output")

        let grant = await runtime.grant(writeRequest, duration: .session)
        XCTAssertEqual(grant.duration, .once)

        let written = try await runtime.execute(writeCall)
        guard case .success(let writeSuccess) = written else {
            return XCTFail("Approved exact preview should write")
        }
        let writeOutput = try JSONDecoder().decode(
            SpreadsheetWriteMutationOutput.self,
            from: try JSONEncoder().encode(writeSuccess.data)
        )
        XCTAssertEqual(writeOutput.outputResourceID, outputID)
        XCTAssertEqual(writeOutput.neutralizedCellCount, 3)

        let outputText = try broker.content(resourceID: outputID)
        XCTAssertTrue(outputText.contains("'=1+1"))
        XCTAssertTrue(outputText.contains("'-5"))
        XCTAssertTrue(outputText.contains("'@SUM(A1)"))
        XCTAssertEqual(try broker.content(resourceID: sourceID), originalSource)

        do {
            _ = try await runtime.execute(writeCall)
            XCTFail("Consumed preview plan must not be reusable")
        } catch let error as ToolRuntimeError {
            guard case .invalidArguments(let tool, let details) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(tool, "spreadsheet.writeMutation@1")
            XCTAssertTrue(details.contains("missing") || details.contains("expired"))
        }
    }

    func testApprovalForOnePlanCannotAuthorizeDifferentPlanOnSameOutput() async throws {
        let broker = TestUserFileBroker()
        let sourceID = broker.register(
            content: "name,value\nA,1\nB,2\n",
            displayName: "source.csv"
        )
        let outputID = broker.register(content: "", displayName: "output.csv")
        let plans = SpreadsheetMutationPlanStore()
        let permissions = PermissionEngine()
        let previewTool = SpreadsheetPreviewMutationTool(
            broker: broker,
            outputBroker: broker,
            plans: plans
        )
        let writeTool = SpreadsheetWriteMutationTool(
            outputBroker: broker,
            plans: plans
        )
        let runtime = ToolRuntime(
            registry: try ToolRegistry(tools: [AnyTool(previewTool), AnyTool(writeTool)]),
            permissions: permissions
        )

        func preview(columns: [String]) async throws -> String {
            let call = try ToolCall.encoding(
                name: "spreadsheet.previewMutation",
                version: "1",
                input: SpreadsheetPreviewMutationInput(
                    sourceResourceID: sourceID,
                    outputResourceID: outputID,
                    transform: SpreadsheetTransformSpec(selectedColumns: columns)
                )
            )
            let first = try await runtime.execute(call)
            switch first {
            case .permissionRequired(let request):
                _ = await runtime.grant(request, duration: .session)
                guard case .success(let success) = try await runtime.execute(call) else {
                    throw SpreadsheetMutationError.planNotFound
                }
                return try JSONDecoder().decode(
                    SpreadsheetMutationPreviewOutput.self,
                    from: JSONEncoder().encode(success.data)
                ).planToken
            case .success(let success):
                return try JSONDecoder().decode(
                    SpreadsheetMutationPreviewOutput.self,
                    from: JSONEncoder().encode(success.data)
                ).planToken
            }
        }

        let tokenA = try await preview(columns: ["name"])
        let tokenB = try await preview(columns: ["value"])
        let callA = try ToolCall.encoding(
            name: "spreadsheet.writeMutation",
            version: "1",
            input: SpreadsheetWriteMutationInput(planToken: tokenA)
        )
        let callB = try ToolCall.encoding(
            name: "spreadsheet.writeMutation",
            version: "1",
            input: SpreadsheetWriteMutationInput(planToken: tokenB)
        )

        guard case .permissionRequired(let requestA) = try await runtime.execute(callA) else {
            return XCTFail("Plan A should request permission")
        }
        _ = await runtime.grant(requestA, duration: .once)

        let wrongPlan = try await runtime.execute(callB)
        guard case .permissionRequired(let requestB) = wrongPlan else {
            return XCTFail("Approval for plan A must not authorize plan B")
        }
        XCTAssertEqual(requestB.resource, requestA.resource)
        XCTAssertNotEqual(requestB.details["planToken"], requestA.details["planToken"])

        guard case .success = try await runtime.execute(callA) else {
            return XCTFail("The exact originally approved plan should still execute")
        }
    }

    func testWriteRefusesNonEmptyDestinationAndSourceEqualsOutputFailsBeforePrompt() async throws {
        let broker = TestUserFileBroker()
        let sourceID = broker.register(
            content: "name,value\nA,1\n",
            displayName: "source.csv"
        )
        let nonEmptyOutputID = broker.register(
            content: "do-not-overwrite",
            displayName: "existing.csv"
        )
        let plans = SpreadsheetMutationPlanStore()
        let runtime = ToolRuntime(
            registry: try ToolRegistry(tools: [
                AnyTool(SpreadsheetPreviewMutationTool(
                    broker: broker,
                    outputBroker: broker,
                    plans: plans
                )),
                AnyTool(SpreadsheetWriteMutationTool(
                    outputBroker: broker,
                    plans: plans
                ))
            ]),
            permissions: PermissionEngine()
        )

        let previewCall = try ToolCall.encoding(
            name: "spreadsheet.previewMutation",
            version: "1",
            input: SpreadsheetPreviewMutationInput(
                sourceResourceID: sourceID,
                outputResourceID: nonEmptyOutputID
            )
        )
        guard case .permissionRequired(let readRequest) = try await runtime.execute(previewCall) else {
            return XCTFail("Expected read permission")
        }
        _ = await runtime.grant(readRequest, duration: .once)
        guard case .success(let previewSuccess) = try await runtime.execute(previewCall) else {
            return XCTFail("Expected preview")
        }
        let preview = try JSONDecoder().decode(
            SpreadsheetMutationPreviewOutput.self,
            from: JSONEncoder().encode(previewSuccess.data)
        )
        let writeCall = try ToolCall.encoding(
            name: "spreadsheet.writeMutation",
            version: "1",
            input: SpreadsheetWriteMutationInput(planToken: preview.planToken)
        )
        guard case .permissionRequired(let writeRequest) = try await runtime.execute(writeCall) else {
            return XCTFail("Expected write approval")
        }
        _ = await runtime.grant(writeRequest, duration: .once)

        do {
            _ = try await runtime.execute(writeCall)
            XCTFail("Existing output data must never be overwritten")
        } catch let error as UserFileAccessError {
            guard case .outputNotEmpty(let id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(id, nonEmptyOutputID)
        }
        XCTAssertEqual(try broker.content(resourceID: nonEmptyOutputID), "do-not-overwrite")

        let sameResourceCall = try ToolCall.encoding(
            name: "spreadsheet.previewMutation",
            version: "1",
            input: SpreadsheetPreviewMutationInput(
                sourceResourceID: sourceID,
                outputResourceID: sourceID
            )
        )
        do {
            _ = try await runtime.execute(sameResourceCall)
            XCTFail("Source and destination must differ before any approval prompt")
        } catch let error as ToolRuntimeError {
            guard case .invalidArguments(let tool, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(tool, "spreadsheet.previewMutation@1")
        }
    }
}
