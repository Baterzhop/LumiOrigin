import Foundation

public struct SpreadsheetProfileInput: Codable, Equatable, Sendable {
    public let resourceID: UserFileResourceID
    public let headerMode: SpreadsheetHeaderMode
    public let delimiter: DelimitedTextDelimiter
    public let maxBytes: Int
    public let maxRows: Int
    public let maxColumns: Int

    public init(
        resourceID: UserFileResourceID,
        headerMode: SpreadsheetHeaderMode = .firstRow,
        delimiter: DelimitedTextDelimiter = .auto,
        maxBytes: Int = SpreadsheetInspectInput.defaultMaxBytes,
        maxRows: Int = SpreadsheetInspectInput.defaultMaxRows,
        maxColumns: Int = SpreadsheetInspectInput.defaultMaxColumns
    ) {
        self.resourceID = resourceID
        self.headerMode = headerMode
        self.delimiter = delimiter
        self.maxBytes = maxBytes
        self.maxRows = maxRows
        self.maxColumns = maxColumns
    }

    private enum CodingKeys: String, CodingKey {
        case resourceID, headerMode, delimiter, maxBytes, maxRows, maxColumns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resourceID = try container.decode(UserFileResourceID.self, forKey: .resourceID)
        headerMode = try container.decodeIfPresent(SpreadsheetHeaderMode.self, forKey: .headerMode) ?? .firstRow
        delimiter = try container.decodeIfPresent(DelimitedTextDelimiter.self, forKey: .delimiter) ?? .auto
        maxBytes = try container.decodeIfPresent(Int.self, forKey: .maxBytes) ?? SpreadsheetInspectInput.defaultMaxBytes
        maxRows = try container.decodeIfPresent(Int.self, forKey: .maxRows) ?? SpreadsheetInspectInput.defaultMaxRows
        maxColumns = try container.decodeIfPresent(Int.self, forKey: .maxColumns) ?? SpreadsheetInspectInput.defaultMaxColumns
    }
}

public struct SpreadsheetNumericProfile: Codable, Equatable, Sendable {
    public let count: Int
    public let minimum: Double
    public let maximum: Double
    public let mean: Double

    public init(count: Int, minimum: Double, maximum: Double, mean: Double) {
        self.count = count
        self.minimum = minimum
        self.maximum = maximum
        self.mean = mean
    }
}

public struct SpreadsheetColumnProfile: Codable, Equatable, Sendable {
    public let columnIndex: Int
    public let name: String
    public let emptyCount: Int
    public let nonEmptyCount: Int
    public let distinctNonEmptyCount: Int
    public let numericCount: Int
    public let booleanLiteralCount: Int
    public let numeric: SpreadsheetNumericProfile?

    public init(
        columnIndex: Int,
        name: String,
        emptyCount: Int,
        nonEmptyCount: Int,
        distinctNonEmptyCount: Int,
        numericCount: Int,
        booleanLiteralCount: Int,
        numeric: SpreadsheetNumericProfile?
    ) {
        self.columnIndex = columnIndex
        self.name = name
        self.emptyCount = emptyCount
        self.nonEmptyCount = nonEmptyCount
        self.distinctNonEmptyCount = distinctNonEmptyCount
        self.numericCount = numericCount
        self.booleanLiteralCount = booleanLiteralCount
        self.numeric = numeric
    }
}

public struct SpreadsheetProfileOutput: Codable, Equatable, Sendable {
    public let resourceID: UserFileResourceID
    public let displayName: String
    public let format: SpreadsheetFormat
    public let rowCount: Int
    public let columnCount: Int
    public let columns: [SpreadsheetColumnProfile]

    public init(snapshot: SpreadsheetTableSnapshot) {
        resourceID = snapshot.resourceID
        displayName = snapshot.displayName
        format = snapshot.format
        rowCount = snapshot.rowCount
        columnCount = snapshot.columnCount

        columns = snapshot.columns.map { column in
            var emptyCount = 0
            var nonEmptyCount = 0
            var distinct: Set<String> = []
            var numericValues: [Double] = []
            var booleanLiteralCount = 0

            for row in snapshot.rows {
                let raw = row.cells[column.index].rawValue
                if raw.isEmpty {
                    emptyCount += 1
                    continue
                }

                nonEmptyCount += 1
                distinct.insert(raw)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let lowered = trimmed.lowercased()
                if lowered == "true" || lowered == "false" {
                    booleanLiteralCount += 1
                }
                if let number = Double(trimmed), number.isFinite {
                    numericValues.append(number)
                }
            }

            let numeric: SpreadsheetNumericProfile?
            if let minimum = numericValues.min(), let maximum = numericValues.max() {
                let sum = numericValues.reduce(0, +)
                numeric = SpreadsheetNumericProfile(
                    count: numericValues.count,
                    minimum: minimum,
                    maximum: maximum,
                    mean: sum / Double(numericValues.count)
                )
            } else {
                numeric = nil
            }

            return SpreadsheetColumnProfile(
                columnIndex: column.index,
                name: column.name,
                emptyCount: emptyCount,
                nonEmptyCount: nonEmptyCount,
                distinctNonEmptyCount: distinct.count,
                numericCount: numericValues.count,
                booleanLiteralCount: booleanLiteralCount,
                numeric: numeric
            )
        }
    }
}

/// Aggregate-only table profiling. It intentionally returns no raw row samples;
/// callers use `spreadsheet.inspect` when they need a bounded preview.
public struct SpreadsheetProfileTool: Tool {
    public static let descriptor = ToolDescriptor(
        name: "spreadsheet.profile",
        version: "1",
        summary: "Compute bounded deterministic column statistics for a user-selected CSV/TSV table.",
        risk: .readOnly,
        capability: .readUserFile,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "resourceID": .object([
                    "type": .string("string"),
                    "description": .string("Opaque Lumi resource ID for a user-selected CSV/TSV file.")
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
                ])
            ]),
            "required": .array([.string("resourceID")]),
            "additionalProperties": .bool(false)
        ])
    )

    private let broker: any UserFileAccessBroker
    private let reader: any SpreadsheetReader

    public init(broker: any UserFileAccessBroker = UnavailableUserFileAccessBroker()) {
        self.broker = broker
        self.reader = DelimitedSpreadsheetReader(broker: broker)
    }

    public init(reader: any SpreadsheetReader, broker: any UserFileAccessBroker) {
        self.reader = reader
        self.broker = broker
    }

    public func resource(for input: SpreadsheetProfileInput) throws -> ResourceScope {
        _ = try broker.descriptor(for: input.resourceID)
        return .userFile(input.resourceID)
    }

    public func permissionRequest(for input: SpreadsheetProfileInput) throws -> PermissionRequest {
        let descriptor = try broker.descriptor(for: input.resourceID)
        return PermissionRequest(
            capability: Self.descriptor.capability,
            resource: .userFile(input.resourceID),
            reason: Self.descriptor.summary,
            resourceDisplayName: descriptor.displayName,
            resourceLocationHint: descriptor.locationHint
        )
    }

    public func execute(_ input: SpreadsheetProfileInput) async throws -> SpreadsheetProfileOutput {
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
        return SpreadsheetProfileOutput(snapshot: snapshot)
    }

    public func metadata(
        for input: SpreadsheetProfileInput,
        output: SpreadsheetProfileOutput
    ) -> [String: JSONValue] {
        [
            "resourceID": .string(output.resourceID.rawValue),
            "displayName": .string(output.displayName),
            "format": .string(output.format.rawValue),
            "rows": .number(Double(output.rowCount)),
            "columns": .number(Double(output.columnCount))
        ]
    }
}
