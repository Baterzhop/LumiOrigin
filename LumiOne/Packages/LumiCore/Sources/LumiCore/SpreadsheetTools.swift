import Foundation

public struct SpreadsheetInspectRange: Codable, Equatable, Sendable {
    /// One-based inclusive source data-row coordinates. Header rows are excluded.
    public let rowStart: Int
    public let rowEnd: Int
    /// One-based inclusive source column coordinates.
    public let columnStart: Int
    public let columnEnd: Int

    public init(rowStart: Int, rowEnd: Int, columnStart: Int, columnEnd: Int) {
        self.rowStart = rowStart
        self.rowEnd = rowEnd
        self.columnStart = columnStart
        self.columnEnd = columnEnd
    }
}

public struct SpreadsheetInspectInput: Codable, Equatable, Sendable {
    public static let defaultMaxBytes = 4_194_304
    public static let defaultMaxRows = 20_000
    public static let defaultMaxColumns = 256
    public static let defaultPreviewRows = 10

    public let resourceID: UserFileResourceID
    public let headerMode: SpreadsheetHeaderMode
    public let delimiter: DelimitedTextDelimiter
    public let maxBytes: Int
    public let maxRows: Int
    public let maxColumns: Int
    public let previewRows: Int
    public let range: SpreadsheetInspectRange?

    public init(
        resourceID: UserFileResourceID,
        headerMode: SpreadsheetHeaderMode = .firstRow,
        delimiter: DelimitedTextDelimiter = .auto,
        maxBytes: Int = defaultMaxBytes,
        maxRows: Int = defaultMaxRows,
        maxColumns: Int = defaultMaxColumns,
        previewRows: Int = defaultPreviewRows,
        range: SpreadsheetInspectRange? = nil
    ) {
        self.resourceID = resourceID
        self.headerMode = headerMode
        self.delimiter = delimiter
        self.maxBytes = maxBytes
        self.maxRows = maxRows
        self.maxColumns = maxColumns
        self.previewRows = previewRows
        self.range = range
    }

    private enum CodingKeys: String, CodingKey {
        case resourceID
        case headerMode
        case delimiter
        case maxBytes
        case maxRows
        case maxColumns
        case previewRows
        case range
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resourceID = try container.decode(UserFileResourceID.self, forKey: .resourceID)
        headerMode = try container.decodeIfPresent(SpreadsheetHeaderMode.self, forKey: .headerMode) ?? .firstRow
        delimiter = try container.decodeIfPresent(DelimitedTextDelimiter.self, forKey: .delimiter) ?? .auto
        maxBytes = try container.decodeIfPresent(Int.self, forKey: .maxBytes) ?? Self.defaultMaxBytes
        maxRows = try container.decodeIfPresent(Int.self, forKey: .maxRows) ?? Self.defaultMaxRows
        maxColumns = try container.decodeIfPresent(Int.self, forKey: .maxColumns) ?? Self.defaultMaxColumns
        previewRows = try container.decodeIfPresent(Int.self, forKey: .previewRows) ?? Self.defaultPreviewRows
        range = try container.decodeIfPresent(SpreadsheetInspectRange.self, forKey: .range)
    }
}

public struct SpreadsheetPreviewRow: Codable, Equatable, Sendable {
    public let rowIndex: Int
    public let values: [String]

    public init(rowIndex: Int, values: [String]) {
        self.rowIndex = rowIndex
        self.values = values
    }
}

public struct SpreadsheetInspectOutput: Codable, Equatable, Sendable {
    public let resourceID: UserFileResourceID
    public let displayName: String
    public let format: SpreadsheetFormat
    public let tableID: SpreadsheetTableID
    public let rowCount: Int
    public let columnCount: Int
    public let columns: [SpreadsheetColumn]
    public let preview: [SpreadsheetPreviewRow]
    public let previewTruncated: Bool
    public let fullRangeIdentity: String?
    /// Stable identity in the original parsed source table when a subrange was requested.
    public let selectedSourceRangeIdentity: String?
    public let sourceByteCount: Int

    public init(
        snapshot: SpreadsheetTableSnapshot,
        previewRows: Int,
        selectedSourceRangeIdentity: String? = nil
    ) {
        resourceID = snapshot.resourceID
        displayName = snapshot.displayName
        format = snapshot.format
        tableID = snapshot.tableID
        rowCount = snapshot.rowCount
        columnCount = snapshot.columnCount
        columns = snapshot.columns
        preview = snapshot.rows.prefix(previewRows).map { row in
            SpreadsheetPreviewRow(
                rowIndex: row.index,
                values: row.cells.map(\.rawValue)
            )
        }
        previewTruncated = snapshot.rowCount > preview.count
        fullRangeIdentity = snapshot.fullRange?.stableIdentity
        self.selectedSourceRangeIdentity = selectedSourceRangeIdentity
        sourceByteCount = snapshot.sourceByteCount
    }
}

/// Read-only typed spreadsheet inspection. The model receives bounded parsed
/// table data, never a filesystem path and never an executable formula/macro.
public struct SpreadsheetInspectTool: Tool {
    public static let descriptor = ToolDescriptor(
        name: "spreadsheet.inspect",
        version: "1",
        summary: "Inspect a bounded CSV or TSV table or an explicit 2D source range from one user-selected file registered with Lumi.",
        risk: .readOnly,
        capability: .readUserFile,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "resourceID": .object([
                    "type": .string("string"),
                    "description": .string("Opaque Lumi resource ID for a user-selected CSV/TSV file. Never pass a filesystem path.")
                ]),
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
                    "maximum": .number(50),
                    "description": .string("Number of parsed data rows returned to the model. Full table contents are not returned by this inspection tool.")
                ]),
                "range": .object([
                    "type": .array([.string("object"), .string("null")]),
                    "properties": .object([
                        "rowStart": .object(["type": .string("integer"), "minimum": .number(1)]),
                        "rowEnd": .object(["type": .string("integer"), "minimum": .number(1)]),
                        "columnStart": .object(["type": .string("integer"), "minimum": .number(1)]),
                        "columnEnd": .object(["type": .string("integer"), "minimum": .number(1)])
                    ]),
                    "required": .array([
                        .string("rowStart"), .string("rowEnd"),
                        .string("columnStart"), .string("columnEnd")
                    ]),
                    "additionalProperties": .bool(false),
                    "description": .string("Optional one-based inclusive 2D range in source data rows/columns.")
                ])
            ]),
            "required": .array([.string("resourceID")]),
            "additionalProperties": .bool(false)
        ])
    )

    private let reader: any SpreadsheetReader
    private let broker: any UserFileAccessBroker

    public init(
        reader: any SpreadsheetReader,
        broker: any UserFileAccessBroker
    ) {
        self.reader = reader
        self.broker = broker
    }

    public init(broker: any UserFileAccessBroker = UnavailableUserFileAccessBroker()) {
        self.broker = broker
        self.reader = DelimitedSpreadsheetReader(broker: broker)
    }

    public func resource(for input: SpreadsheetInspectInput) throws -> ResourceScope {
        _ = try broker.descriptor(for: input.resourceID)
        try validateRangeShape(input.range)
        return .userFile(input.resourceID)
    }

    public func permissionRequest(for input: SpreadsheetInspectInput) throws -> PermissionRequest {
        let descriptor = try broker.descriptor(for: input.resourceID)
        try validatePreviewRows(input.previewRows)
        try validateRangeShape(input.range)
        return PermissionRequest(
            capability: Self.descriptor.capability,
            resource: .userFile(input.resourceID),
            reason: Self.descriptor.summary,
            resourceDisplayName: descriptor.displayName,
            resourceLocationHint: descriptor.locationHint
        )
    }

    public func execute(_ input: SpreadsheetInspectInput) async throws -> SpreadsheetInspectOutput {
        try validatePreviewRows(input.previewRows)
        try validateRangeShape(input.range)
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

        guard let range = input.range else {
            return SpreadsheetInspectOutput(snapshot: source, previewRows: input.previewRows)
        }

        let sourceRange = try validatedSourceRange(range, in: source)
        let sliced = slice(source, sourceRange: sourceRange)
        return SpreadsheetInspectOutput(
            snapshot: sliced,
            previewRows: input.previewRows,
            selectedSourceRangeIdentity: sourceRange.stableIdentity
        )
    }

    public func metadata(
        for input: SpreadsheetInspectInput,
        output: SpreadsheetInspectOutput
    ) -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [
            "resourceID": .string(output.resourceID.rawValue),
            "displayName": .string(output.displayName),
            "format": .string(output.format.rawValue),
            "rows": .number(Double(output.rowCount)),
            "columns": .number(Double(output.columnCount)),
            "previewRows": .number(Double(output.preview.count)),
            "previewTruncated": .bool(output.previewTruncated)
        ]
        if let selected = output.selectedSourceRangeIdentity {
            metadata["selectedSourceRange"] = .string(selected)
        }
        return metadata
    }

    /// Row values are available to the model only in the current tool turn.
    /// Durable conversation history keeps structural metadata but not the cells.
    public func historyOutput(
        for input: SpreadsheetInspectInput,
        output: SpreadsheetInspectOutput
    ) throws -> JSONValue {
        var object: [String: JSONValue] = [
            "resourceID": .string(output.resourceID.rawValue),
            "displayName": .string(output.displayName),
            "format": .string(output.format.rawValue),
            "tableID": .string(output.tableID.rawValue),
            "rowCount": .number(Double(output.rowCount)),
            "columnCount": .number(Double(output.columnCount)),
            "previewRowsReturned": .number(Double(output.preview.count)),
            "previewTruncated": .bool(output.previewTruncated),
            "preview": .string("<redacted:spreadsheet-preview>"),
            "sourceByteCount": .number(Double(output.sourceByteCount))
        ]
        if let selected = output.selectedSourceRangeIdentity {
            object["selectedSourceRange"] = .string(selected)
        }
        return .object(object)
    }

    private func validatePreviewRows(_ count: Int) throws {
        guard (1...50).contains(count) else {
            throw SpreadsheetError.invalidReadLimit("previewRows must be between 1 and 50")
        }
    }

    private func validateRangeShape(_ range: SpreadsheetInspectRange?) throws {
        guard let range else { return }
        guard
            range.rowStart >= 1,
            range.columnStart >= 1,
            range.rowEnd >= range.rowStart,
            range.columnEnd >= range.columnStart
        else {
            throw SpreadsheetError.invalidReadLimit(
                "range coordinates must be one-based inclusive with start <= end"
            )
        }
        let rowSpan = range.rowEnd - range.rowStart + 1
        let columnSpan = range.columnEnd - range.columnStart + 1
        guard rowSpan <= 10_000, columnSpan <= 256, rowSpan * columnSpan <= 100_000 else {
            throw SpreadsheetError.invalidReadLimit(
                "requested range exceeds the 100,000-cell inspection budget"
            )
        }
    }

    private func validatedSourceRange(
        _ range: SpreadsheetInspectRange,
        in snapshot: SpreadsheetTableSnapshot
    ) throws -> SpreadsheetRange {
        guard
            range.rowEnd <= snapshot.rowCount,
            range.columnEnd <= snapshot.columnCount
        else {
            throw SpreadsheetError.invalidReadLimit(
                "requested range exceeds parsed table bounds \(snapshot.rowCount)x\(snapshot.columnCount)"
            )
        }
        return SpreadsheetRange(
            tableID: snapshot.tableID,
            rowStart: range.rowStart,
            rowEnd: range.rowEnd,
            columnStart: range.columnStart,
            columnEnd: range.columnEnd
        )
    }

    private func slice(
        _ source: SpreadsheetTableSnapshot,
        sourceRange: SpreadsheetRange
    ) -> SpreadsheetTableSnapshot {
        let sourceColumns = Array(source.columns[(sourceRange.columnStart - 1)...(sourceRange.columnEnd - 1)])
        let columns = sourceColumns.enumerated().map { offset, column in
            SpreadsheetColumn(index: offset, name: column.name)
        }
        let sourceRows = Array(source.rows[(sourceRange.rowStart - 1)...(sourceRange.rowEnd - 1)])
        let rows = sourceRows.enumerated().map { rowOffset, sourceRow in
            SpreadsheetRow(
                index: rowOffset + 1,
                cells: Array(sourceRow.cells[(sourceRange.columnStart - 1)...(sourceRange.columnEnd - 1)])
            )
        }
        return SpreadsheetTableSnapshot(
            resourceID: source.resourceID,
            displayName: source.displayName,
            format: source.format,
            tableID: SpreadsheetTableID(
                rawValue: source.tableID.rawValue + ":" + sourceRange.stableIdentity
            ),
            columns: columns,
            rows: rows,
            sourceByteCount: source.sourceByteCount
        )
    }
}
