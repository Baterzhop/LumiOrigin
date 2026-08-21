import Foundation

public struct SpreadsheetQueryInput: Codable, Equatable, Sendable {
    public let resourceID: UserFileResourceID
    public let transform: SpreadsheetTransformSpec
    public let headerMode: SpreadsheetHeaderMode
    public let delimiter: DelimitedTextDelimiter
    public let maxBytes: Int
    public let maxRows: Int
    public let maxColumns: Int
    public let previewRows: Int

    public init(
        resourceID: UserFileResourceID,
        transform: SpreadsheetTransformSpec = SpreadsheetTransformSpec(),
        headerMode: SpreadsheetHeaderMode = .firstRow,
        delimiter: DelimitedTextDelimiter = .auto,
        maxBytes: Int = SpreadsheetInspectInput.defaultMaxBytes,
        maxRows: Int = SpreadsheetInspectInput.defaultMaxRows,
        maxColumns: Int = SpreadsheetInspectInput.defaultMaxColumns,
        previewRows: Int = SpreadsheetInspectInput.defaultPreviewRows
    ) {
        self.resourceID = resourceID
        self.transform = transform
        self.headerMode = headerMode
        self.delimiter = delimiter
        self.maxBytes = maxBytes
        self.maxRows = maxRows
        self.maxColumns = maxColumns
        self.previewRows = previewRows
    }

    private enum CodingKeys: String, CodingKey {
        case resourceID, transform, headerMode, delimiter, maxBytes, maxRows, maxColumns, previewRows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resourceID = try container.decode(UserFileResourceID.self, forKey: .resourceID)
        transform = try container.decodeIfPresent(SpreadsheetTransformSpec.self, forKey: .transform)
            ?? SpreadsheetTransformSpec()
        headerMode = try container.decodeIfPresent(SpreadsheetHeaderMode.self, forKey: .headerMode) ?? .firstRow
        delimiter = try container.decodeIfPresent(DelimitedTextDelimiter.self, forKey: .delimiter) ?? .auto
        maxBytes = try container.decodeIfPresent(Int.self, forKey: .maxBytes) ?? SpreadsheetInspectInput.defaultMaxBytes
        maxRows = try container.decodeIfPresent(Int.self, forKey: .maxRows) ?? SpreadsheetInspectInput.defaultMaxRows
        maxColumns = try container.decodeIfPresent(Int.self, forKey: .maxColumns) ?? SpreadsheetInspectInput.defaultMaxColumns
        previewRows = try container.decodeIfPresent(Int.self, forKey: .previewRows) ?? SpreadsheetInspectInput.defaultPreviewRows
    }
}

public struct SpreadsheetQueryRow: Codable, Equatable, Sendable {
    public let resultRowIndex: Int
    public let sourceRowIndex: Int
    public let values: [String]

    public init(resultRowIndex: Int, sourceRowIndex: Int, values: [String]) {
        self.resultRowIndex = resultRowIndex
        self.sourceRowIndex = sourceRowIndex
        self.values = values
    }
}

public struct SpreadsheetQueryOutput: Codable, Equatable, Sendable {
    public let resourceID: UserFileResourceID
    public let displayName: String
    public let rowCount: Int
    public let columnCount: Int
    public let columns: [String]
    public let preview: [SpreadsheetQueryRow]
    public let previewTruncated: Bool

    public init(result: SpreadsheetTransformResult, previewRows: Int) {
        let snapshot = result.snapshot
        resourceID = snapshot.resourceID
        displayName = snapshot.displayName
        rowCount = snapshot.rowCount
        columnCount = snapshot.columnCount
        columns = snapshot.columns.map(\.name)
        preview = Array(snapshot.rows.prefix(previewRows)).enumerated().map { offset, row in
            SpreadsheetQueryRow(
                resultRowIndex: row.index,
                sourceRowIndex: result.sourceRowIndices[offset],
                values: row.cells.map(\.rawValue)
            )
        }
        previewTruncated = snapshot.rowCount > preview.count
    }
}

public struct SpreadsheetQueryTool: Tool {
    public static let descriptor = ToolDescriptor(
        name: "spreadsheet.query",
        version: "1",
        summary: "Select, filter and sort a bounded CSV/TSV table without modifying the source file.",
        risk: .readOnly,
        capability: .readUserFile,
        inputSchema: SpreadsheetToolSchemas.queryInput
    )

    private let broker: any UserFileAccessBroker
    private let reader: any SpreadsheetReader
    private let engine: SpreadsheetTransformEngine

    public init(broker: any UserFileAccessBroker = UnavailableUserFileAccessBroker()) {
        self.broker = broker
        self.reader = DelimitedSpreadsheetReader(broker: broker)
        self.engine = SpreadsheetTransformEngine()
    }

    public func resource(for input: SpreadsheetQueryInput) throws -> ResourceScope {
        _ = try broker.descriptor(for: input.resourceID)
        return .userFile(input.resourceID)
    }

    public func permissionRequest(for input: SpreadsheetQueryInput) throws -> PermissionRequest {
        let descriptor = try broker.descriptor(for: input.resourceID)
        try SpreadsheetToolSchemas.validatePreviewRows(input.previewRows)
        return PermissionRequest(
            capability: Self.descriptor.capability,
            resource: .userFile(input.resourceID),
            reason: Self.descriptor.summary,
            resourceDisplayName: descriptor.displayName,
            resourceLocationHint: descriptor.locationHint
        )
    }

    public func execute(_ input: SpreadsheetQueryInput) async throws -> SpreadsheetQueryOutput {
        try SpreadsheetToolSchemas.validatePreviewRows(input.previewRows)
        let source = try await reader.read(
            SpreadsheetReadRequest(
                resourceID: input.resourceID,
                headerMode: input.headerMode,
                delimiter: input.delimiter,
                maxBytes: input.maxBytes,
                maxRows: input.maxRows,
                maxColumns: input.maxColumns
            )
        )
        let result = try engine.apply(input.transform, to: source)
        return SpreadsheetQueryOutput(result: result, previewRows: input.previewRows)
    }

    public func historyOutput(
        for input: SpreadsheetQueryInput,
        output: SpreadsheetQueryOutput
    ) throws -> JSONValue {
        .object([
            "resourceID": .string(output.resourceID.rawValue),
            "displayName": .string(output.displayName),
            "rowCount": .number(Double(output.rowCount)),
            "columnCount": .number(Double(output.columnCount)),
            "columns": .array(output.columns.map { .string($0) }),
            "preview": .string("<redacted:ephemeral-spreadsheet-row-values>"),
            "previewTruncated": .bool(output.previewTruncated)
        ])
    }
}

public struct SpreadsheetPreviewMutationInput: Codable, Equatable, Sendable {
    public let sourceResourceID: UserFileResourceID
    public let outputResourceID: UserFileResourceID
    public let transform: SpreadsheetTransformSpec
    public let headerMode: SpreadsheetHeaderMode
    public let delimiter: DelimitedTextDelimiter
    public let maxBytes: Int
    public let maxRows: Int
    public let maxColumns: Int
    public let previewRows: Int

    public init(
        sourceResourceID: UserFileResourceID,
        outputResourceID: UserFileResourceID,
        transform: SpreadsheetTransformSpec = SpreadsheetTransformSpec(),
        headerMode: SpreadsheetHeaderMode = .firstRow,
        delimiter: DelimitedTextDelimiter = .auto,
        maxBytes: Int = SpreadsheetInspectInput.defaultMaxBytes,
        maxRows: Int = SpreadsheetInspectInput.defaultMaxRows,
        maxColumns: Int = SpreadsheetInspectInput.defaultMaxColumns,
        previewRows: Int = SpreadsheetInspectInput.defaultPreviewRows
    ) {
        self.sourceResourceID = sourceResourceID
        self.outputResourceID = outputResourceID
        self.transform = transform
        self.headerMode = headerMode
        self.delimiter = delimiter
        self.maxBytes = maxBytes
        self.maxRows = maxRows
        self.maxColumns = maxColumns
        self.previewRows = previewRows
    }

    private enum CodingKeys: String, CodingKey {
        case sourceResourceID, outputResourceID, transform, headerMode, delimiter, maxBytes, maxRows, maxColumns, previewRows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceResourceID = try container.decode(UserFileResourceID.self, forKey: .sourceResourceID)
        outputResourceID = try container.decode(UserFileResourceID.self, forKey: .outputResourceID)
        transform = try container.decodeIfPresent(SpreadsheetTransformSpec.self, forKey: .transform)
            ?? SpreadsheetTransformSpec()
        headerMode = try container.decodeIfPresent(SpreadsheetHeaderMode.self, forKey: .headerMode) ?? .firstRow
        delimiter = try container.decodeIfPresent(DelimitedTextDelimiter.self, forKey: .delimiter) ?? .auto
        maxBytes = try container.decodeIfPresent(Int.self, forKey: .maxBytes) ?? SpreadsheetInspectInput.defaultMaxBytes
        maxRows = try container.decodeIfPresent(Int.self, forKey: .maxRows) ?? SpreadsheetInspectInput.defaultMaxRows
        maxColumns = try container.decodeIfPresent(Int.self, forKey: .maxColumns) ?? SpreadsheetInspectInput.defaultMaxColumns
        previewRows = try container.decodeIfPresent(Int.self, forKey: .previewRows) ?? SpreadsheetInspectInput.defaultPreviewRows
    }
}

public struct SpreadsheetMutationPreviewOutput: Codable, Equatable, Sendable {
    public let planToken: String
    public let sourceResourceID: UserFileResourceID
    public let outputResourceID: UserFileResourceID
    public let rowCount: Int
    public let columnCount: Int
    public let columns: [String]
    public let preview: [SpreadsheetQueryRow]
    public let previewTruncated: Bool

    public init(plan: SpreadsheetMutationPlan, previewRows: Int) {
        planToken = plan.token
        sourceResourceID = plan.sourceResourceID
        outputResourceID = plan.outputResourceID
        rowCount = plan.transformed.rowCount
        columnCount = plan.transformed.columnCount
        columns = plan.transformed.columns.map(\.name)
        preview = Array(plan.transformed.rows.prefix(previewRows)).enumerated().map { offset, row in
            SpreadsheetQueryRow(
                resultRowIndex: row.index,
                sourceRowIndex: plan.sourceRowIndices[offset],
                values: row.cells.map(\.rawValue)
            )
        }
        previewTruncated = plan.transformed.rowCount > preview.count
    }
}

public struct SpreadsheetPreviewMutationTool: Tool {
    public static let descriptor = ToolDescriptor(
        name: "spreadsheet.previewMutation",
        version: "1",
        summary: "Build an immutable preview for an exact CSV/TSV transform before any write approval.",
        risk: .readOnly,
        capability: .readUserFile,
        inputSchema: SpreadsheetToolSchemas.previewMutationInput
    )

    private let broker: any UserFileAccessBroker
    private let outputBroker: any UserFileWriteBroker
    private let reader: any SpreadsheetReader
    private let engine = SpreadsheetTransformEngine()
    private let plans: SpreadsheetMutationPlanStore

    public init(
        broker: any UserFileAccessBroker,
        outputBroker: any UserFileWriteBroker,
        plans: SpreadsheetMutationPlanStore
    ) {
        self.broker = broker
        self.outputBroker = outputBroker
        self.reader = DelimitedSpreadsheetReader(broker: broker)
        self.plans = plans
    }

    public func resource(for input: SpreadsheetPreviewMutationInput) throws -> ResourceScope {
        _ = try broker.descriptor(for: input.sourceResourceID)
        _ = try outputBroker.descriptor(for: input.outputResourceID)
        guard input.sourceResourceID != input.outputResourceID else {
            throw SpreadsheetMutationError.sourceEqualsOutput
        }
        return .userFile(input.sourceResourceID)
    }

    public func permissionRequest(for input: SpreadsheetPreviewMutationInput) throws -> PermissionRequest {
        let source = try broker.descriptor(for: input.sourceResourceID)
        _ = try outputBroker.descriptor(for: input.outputResourceID)
        guard input.sourceResourceID != input.outputResourceID else {
            throw SpreadsheetMutationError.sourceEqualsOutput
        }
        try SpreadsheetToolSchemas.validatePreviewRows(input.previewRows)
        return PermissionRequest(
            capability: Self.descriptor.capability,
            resource: .userFile(input.sourceResourceID),
            reason: Self.descriptor.summary,
            resourceDisplayName: source.displayName,
            resourceLocationHint: source.locationHint
        )
    }

    public func execute(
        _ input: SpreadsheetPreviewMutationInput
    ) async throws -> SpreadsheetMutationPreviewOutput {
        try SpreadsheetToolSchemas.validatePreviewRows(input.previewRows)
        guard input.sourceResourceID != input.outputResourceID else {
            throw SpreadsheetMutationError.sourceEqualsOutput
        }
        _ = try outputBroker.descriptor(for: input.outputResourceID)

        let source = try await reader.read(
            SpreadsheetReadRequest(
                resourceID: input.sourceResourceID,
                headerMode: input.headerMode,
                delimiter: input.delimiter,
                maxBytes: input.maxBytes,
                maxRows: input.maxRows,
                maxColumns: input.maxColumns
            )
        )
        let result = try engine.apply(input.transform, to: source)
        let plan = plans.store(
            sourceResourceID: input.sourceResourceID,
            outputResourceID: input.outputResourceID,
            spec: input.transform,
            result: result
        )
        return SpreadsheetMutationPreviewOutput(plan: plan, previewRows: input.previewRows)
    }

    public func historyOutput(
        for input: SpreadsheetPreviewMutationInput,
        output: SpreadsheetMutationPreviewOutput
    ) throws -> JSONValue {
        .object([
            "planToken": .string("<redacted:ephemeral-plan-token>"),
            "sourceResourceID": .string(output.sourceResourceID.rawValue),
            "outputResourceID": .string(output.outputResourceID.rawValue),
            "rowCount": .number(Double(output.rowCount)),
            "columnCount": .number(Double(output.columnCount)),
            "columns": .array(output.columns.map { .string($0) }),
            "preview": .string("<redacted:ephemeral-spreadsheet-row-values>"),
            "previewTruncated": .bool(output.previewTruncated)
        ])
    }
}

public struct SpreadsheetWriteMutationInput: Codable, Equatable, Sendable {
    public let planToken: String

    public init(planToken: String) {
        self.planToken = planToken
    }
}

public struct SpreadsheetWriteMutationOutput: Codable, Equatable, Sendable {
    public let outputResourceID: UserFileResourceID
    public let displayName: String
    public let format: SpreadsheetFormat
    public let byteCount: Int
    public let rowCount: Int
    public let columnCount: Int
    public let neutralizedCellCount: Int

    public init(_ result: SpreadsheetExportResult) {
        outputResourceID = result.outputResourceID
        displayName = result.displayName
        format = result.format
        byteCount = result.byteCount
        rowCount = result.rowCount
        columnCount = result.columnCount
        neutralizedCellCount = result.neutralizedCellCount
    }
}

public struct SpreadsheetWriteMutationTool: Tool {
    public static let descriptor = ToolDescriptor(
        name: "spreadsheet.writeMutation",
        version: "1",
        summary: "Write one previously previewed immutable spreadsheet transform to a separate empty CSV/TSV output file.",
        risk: .userWrite,
        capability: .writeUserFile,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "planToken": .object([
                    "type": .string("string"),
                    "description": .string("Ephemeral plan token returned by spreadsheet.previewMutation in the current run.")
                ])
            ]),
            "required": .array([.string("planToken")]),
            "additionalProperties": .bool(false)
        ])
    )

    private let outputBroker: any UserFileWriteBroker
    private let exporter: any SpreadsheetExporter
    private let plans: SpreadsheetMutationPlanStore

    public init(
        outputBroker: any UserFileWriteBroker,
        exporter: any SpreadsheetExporter,
        plans: SpreadsheetMutationPlanStore
    ) {
        self.outputBroker = outputBroker
        self.exporter = exporter
        self.plans = plans
    }

    public init(
        outputBroker: any UserFileWriteBroker,
        plans: SpreadsheetMutationPlanStore
    ) {
        self.outputBroker = outputBroker
        self.exporter = DelimitedSpreadsheetWriter(broker: outputBroker)
        self.plans = plans
    }

    public func resource(for input: SpreadsheetWriteMutationInput) throws -> ResourceScope {
        let plan = try plans.plan(token: input.planToken)
        _ = try outputBroker.descriptor(for: plan.outputResourceID)
        return .userFile(plan.outputResourceID)
    }

    public func permissionRequest(
        for input: SpreadsheetWriteMutationInput
    ) throws -> PermissionRequest {
        let plan = try plans.plan(token: input.planToken)
        let output = try outputBroker.descriptor(for: plan.outputResourceID)
        let columnNames = plan.transformed.columns.map(\.name).joined(separator: ", ")
        return PermissionRequest(
            capability: Self.descriptor.capability,
            resource: .userFile(plan.outputResourceID),
            reason: "Write the exact previewed \(plan.transformed.rowCount)-row × \(plan.transformed.columnCount)-column table to new output \(output.displayName).",
            resourceDisplayName: output.displayName,
            resourceLocationHint: output.locationHint,
            details: [
                "operation": "spreadsheet.writeMutation",
                "planToken": plan.token,
                "sourceResourceID": plan.sourceResourceID.rawValue,
                "outputResourceID": plan.outputResourceID.rawValue,
                "rows": String(plan.transformed.rowCount),
                "columns": String(plan.transformed.columnCount),
                "columnNames": columnNames,
                "formulaInjectionDefense": SpreadsheetFormulaInjectionPolicy.escapeDangerousPrefixes.rawValue,
                "overwritePolicy": "require-empty-output"
            ]
        )
    }

    public func execute(
        _ input: SpreadsheetWriteMutationInput
    ) async throws -> SpreadsheetWriteMutationOutput {
        let plan = try plans.plan(token: input.planToken)
        let result = try await exporter.export(
            plan.transformed,
            to: plan.outputResourceID
        )
        plans.consume(token: plan.token)
        return SpreadsheetWriteMutationOutput(result)
    }

    public func historyArguments(for input: SpreadsheetWriteMutationInput) throws -> JSONValue {
        .object([
            "planToken": .string("<redacted:ephemeral-plan-token>")
        ])
    }
}

private enum SpreadsheetToolSchemas {
    static let transform: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "selectedColumns": .object([
                "type": .array([.string("array"), .string("null")]),
                "items": .object(["type": .string("string")])
            ]),
            "filter": .object([
                "type": .array([.string("object"), .string("null")]),
                "properties": .object([
                    "column": .object(["type": .string("string")]),
                    "operation": .object([
                        "type": .string("string"),
                        "enum": .array(SpreadsheetFilterOperator.allCases.map { .string($0.rawValue) })
                    ]),
                    "value": .object(["type": .array([.string("string"), .string("null")])]),
                    "caseSensitive": .object(["type": .string("boolean")])
                ]),
                "required": .array([
                    .string("column"), .string("operation"), .string("caseSensitive")
                ]),
                "additionalProperties": .bool(false)
            ]),
            "sort": .object([
                "type": .array([.string("object"), .string("null")]),
                "properties": .object([
                    "column": .object(["type": .string("string")]),
                    "direction": .object([
                        "type": .string("string"),
                        "enum": .array(SpreadsheetSortDirection.allCases.map { .string($0.rawValue) })
                    ]),
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array(SpreadsheetSortMode.allCases.map { .string($0.rawValue) })
                    ])
                ]),
                "required": .array([.string("column"), .string("direction"), .string("mode")]),
                "additionalProperties": .bool(false)
            ])
        ]),
        "additionalProperties": .bool(false)
    ])

    static let queryInput: JSONValue = makeInput(sourceKey: "resourceID", includesOutput: false)
    static let previewMutationInput: JSONValue = makeInput(sourceKey: "sourceResourceID", includesOutput: true)

    static func validatePreviewRows(_ count: Int) throws {
        guard (1...50).contains(count) else {
            throw SpreadsheetError.invalidReadLimit("previewRows must be between 1 and 50")
        }
    }

    private static func makeInput(sourceKey: String, includesOutput: Bool) -> JSONValue {
        var properties: [String: JSONValue] = [
            sourceKey: .object([
                "type": .string("string"),
                "description": .string("Opaque Lumi resource ID for a user-selected CSV/TSV source. Never pass a filesystem path.")
            ]),
            "transform": transform,
            "headerMode": .object([
                "type": .string("string"),
                "enum": .array([.string("firstRow"), .string("none")])
            ]),
            "delimiter": .object([
                "type": .string("string"),
                "enum": .array(DelimitedTextDelimiter.allCases.map { .string($0.rawValue) })
            ]),
            "maxBytes": .object([
                "type": .string("integer"),
                "minimum": .number(1),
                "maximum": .number(16_777_216)
            ]),
            "maxRows": .object([
                "type": .string("integer"),
                "minimum": .number(1),
                "maximum": .number(100_000)
            ]),
            "maxColumns": .object([
                "type": .string("integer"),
                "minimum": .number(1),
                "maximum": .number(2_048)
            ]),
            "previewRows": .object([
                "type": .string("integer"),
                "minimum": .number(1),
                "maximum": .number(50)
            ])
        ]
        var required: [JSONValue] = [.string(sourceKey)]
        if includesOutput {
            properties["outputResourceID"] = .object([
                "type": .string("string"),
                "description": .string("Opaque Lumi resource ID for a separate empty user-selected CSV/TSV output file.")
            ])
            required.append(.string("outputResourceID"))
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required),
            "additionalProperties": .bool(false)
        ])
    }
}
