import Foundation

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

    public init(
        resourceID: UserFileResourceID,
        headerMode: SpreadsheetHeaderMode = .firstRow,
        delimiter: DelimitedTextDelimiter = .auto,
        maxBytes: Int = defaultMaxBytes,
        maxRows: Int = defaultMaxRows,
        maxColumns: Int = defaultMaxColumns,
        previewRows: Int = defaultPreviewRows
    ) {
        self.resourceID = resourceID
        self.headerMode = headerMode
        self.delimiter = delimiter
        self.maxBytes = maxBytes
        self.maxRows = maxRows
        self.maxColumns = maxColumns
        self.previewRows = previewRows
    }

    private enum CodingKeys: String, CodingKey {
        case resourceID
        case headerMode
        case delimiter
        case maxBytes
        case maxRows
        case maxColumns
        case previewRows
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
    public let sourceByteCount: Int

    public init(snapshot: SpreadsheetTableSnapshot, previewRows: Int) {
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
        sourceByteCount = snapshot.sourceByteCount
    }
}

/// Read-only typed spreadsheet inspection. The model receives bounded parsed
/// table data, never a filesystem path and never an executable formula/macro.
public struct SpreadsheetInspectTool: Tool {
    public static let descriptor = ToolDescriptor(
        name: "spreadsheet.inspect",
        version: "1",
        summary: "Inspect a bounded CSV or TSV table from one user-selected file registered with Lumi.",
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
        return .userFile(input.resourceID)
    }

    public func permissionRequest(for input: SpreadsheetInspectInput) throws -> PermissionRequest {
        let descriptor = try broker.descriptor(for: input.resourceID)
        try validatePreviewRows(input.previewRows)
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
        let snapshot = try await reader.read(
            SpreadsheetReadRequest(
                resourceID: input.resourceID,
                headerMode: input.headerMode,
                delimiter: input.delimiter,
                maxBytes: input.maxBytes,
                maxRows: input.maxRows,
                maxColumns: input.maxColumns
            )
        )
        return SpreadsheetInspectOutput(snapshot: snapshot, previewRows: input.previewRows)
    }

    public func metadata(
        for input: SpreadsheetInspectInput,
        output: SpreadsheetInspectOutput
    ) -> [String: JSONValue] {
        [
            "resourceID": .string(output.resourceID.rawValue),
            "displayName": .string(output.displayName),
            "format": .string(output.format.rawValue),
            "rows": .number(Double(output.rowCount)),
            "columns": .number(Double(output.columnCount)),
            "previewRows": .number(Double(output.preview.count)),
            "previewTruncated": .bool(output.previewTruncated)
        ]
    }

    /// Row values are available to the model only in the current tool turn.
    /// Durable conversation history keeps structural metadata but not the cells.
    public func historyOutput(
        for input: SpreadsheetInspectInput,
        output: SpreadsheetInspectOutput
    ) throws -> JSONValue {
        .object([
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
        ])
    }

    private func validatePreviewRows(_ count: Int) throws {
        guard (1...50).contains(count) else {
            throw SpreadsheetError.invalidReadLimit("previewRows must be between 1 and 50")
        }
    }
}
