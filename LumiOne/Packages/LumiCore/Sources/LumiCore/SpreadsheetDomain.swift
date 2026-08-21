import Foundation

public enum SpreadsheetFormat: String, Codable, Sendable {
    case csv
    case tsv
    case xlsx
}

public enum SpreadsheetCellKind: String, Codable, Sendable {
    case empty
    case text
    case integer
    case decimal
    case boolean
}

/// Format-neutral cell representation. Delimited-text adapters deliberately
/// preserve non-empty source fields as `.text`; they do not guess that `00123`
/// is an integer and thereby destroy user data. Richer adapters may provide
/// typed values while keeping the original `rawValue` for provenance.
public struct SpreadsheetCell: Codable, Equatable, Sendable {
    public let kind: SpreadsheetCellKind
    public let rawValue: String

    public init(kind: SpreadsheetCellKind, rawValue: String) {
        self.kind = kind
        self.rawValue = rawValue
    }

    public static func losslessDelimitedText(_ rawValue: String) -> SpreadsheetCell {
        SpreadsheetCell(
            kind: rawValue.isEmpty ? .empty : .text,
            rawValue: rawValue
        )
    }
}

public struct SpreadsheetTableID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct SpreadsheetColumn: Codable, Equatable, Sendable {
    /// Zero-based stable column position inside the parsed table.
    public let index: Int
    public let name: String

    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }
}

public struct SpreadsheetRow: Codable, Equatable, Sendable {
    /// One-based data-row index, excluding an optional header row.
    public let index: Int
    public let cells: [SpreadsheetCell]

    public init(index: Int, cells: [SpreadsheetCell]) {
        self.index = index
        self.cells = cells
    }
}

public struct SpreadsheetRange: Hashable, Codable, Sendable {
    public let tableID: SpreadsheetTableID
    public let rowStart: Int
    public let rowEnd: Int
    public let columnStart: Int
    public let columnEnd: Int

    public init(
        tableID: SpreadsheetTableID,
        rowStart: Int,
        rowEnd: Int,
        columnStart: Int,
        columnEnd: Int
    ) {
        self.tableID = tableID
        self.rowStart = rowStart
        self.rowEnd = rowEnd
        self.columnStart = columnStart
        self.columnEnd = columnEnd
    }

    public var stableIdentity: String {
        "\(tableID.rawValue):r\(rowStart)-\(rowEnd):c\(columnStart)-\(columnEnd)"
    }
}

public struct SpreadsheetTableSnapshot: Codable, Equatable, Sendable {
    public let resourceID: UserFileResourceID
    public let displayName: String
    public let format: SpreadsheetFormat
    public let tableID: SpreadsheetTableID
    public let columns: [SpreadsheetColumn]
    public let rows: [SpreadsheetRow]
    public let sourceByteCount: Int

    public init(
        resourceID: UserFileResourceID,
        displayName: String,
        format: SpreadsheetFormat,
        tableID: SpreadsheetTableID,
        columns: [SpreadsheetColumn],
        rows: [SpreadsheetRow],
        sourceByteCount: Int
    ) {
        self.resourceID = resourceID
        self.displayName = displayName
        self.format = format
        self.tableID = tableID
        self.columns = columns
        self.rows = rows
        self.sourceByteCount = sourceByteCount
    }

    public var rowCount: Int { rows.count }
    public var columnCount: Int { columns.count }

    public var fullRange: SpreadsheetRange? {
        guard !rows.isEmpty, !columns.isEmpty else { return nil }
        return SpreadsheetRange(
            tableID: tableID,
            rowStart: 1,
            rowEnd: rows.count,
            columnStart: 1,
            columnEnd: columns.count
        )
    }
}

public enum SpreadsheetHeaderMode: String, Codable, Sendable {
    case firstRow
    case none
}

public enum DelimitedTextDelimiter: String, Codable, CaseIterable, Sendable {
    case auto
    case comma
    case tab
    case semicolon

    public var character: Character? {
        switch self {
        case .auto: return nil
        case .comma: return ","
        case .tab: return "\t"
        case .semicolon: return ";"
        }
    }
}

public struct SpreadsheetReadRequest: Codable, Equatable, Sendable {
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
        maxBytes: Int = 4_194_304,
        maxRows: Int = 20_000,
        maxColumns: Int = 256
    ) {
        self.resourceID = resourceID
        self.headerMode = headerMode
        self.delimiter = delimiter
        self.maxBytes = maxBytes
        self.maxRows = maxRows
        self.maxColumns = maxColumns
    }
}

public protocol SpreadsheetReader: Sendable {
    func read(_ request: SpreadsheetReadRequest) async throws -> SpreadsheetTableSnapshot
}

/// Format-neutral boundary for future CSV/XLSX writers. Implementations own the
/// actual serialization and output-resource mechanics; AgentRuntime does not.
public protocol SpreadsheetWriter: Sendable {
    func write(
        _ snapshot: SpreadsheetTableSnapshot,
        to outputResourceID: UserFileResourceID
    ) async throws
}

public enum SpreadsheetError: Error, CustomStringConvertible, Sendable, Equatable {
    case unsupportedFormat(String)
    case invalidReadLimit(String)
    case inputTooLarge(maxBytes: Int)
    case rowLimitExceeded(maxRows: Int)
    case columnLimitExceeded(maxColumns: Int)
    case emptyTable
    case malformedDelimitedText(row: Int, column: Int, reason: String)
    case raggedRow(row: Int, expectedColumns: Int, actualColumns: Int)
    case invalidHeader(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let name):
            return "Unsupported spreadsheet format for \(name)."
        case .invalidReadLimit(let detail):
            return "Invalid spreadsheet read limit: \(detail)."
        case .inputTooLarge(let maxBytes):
            return "Spreadsheet input exceeds the configured \(maxBytes)-byte limit."
        case .rowLimitExceeded(let maxRows):
            return "Spreadsheet exceeds the configured \(maxRows)-row limit."
        case .columnLimitExceeded(let maxColumns):
            return "Spreadsheet exceeds the configured \(maxColumns)-column limit."
        case .emptyTable:
            return "Spreadsheet contains no usable table data."
        case .malformedDelimitedText(let row, let column, let reason):
            return "Malformed delimited text at row \(row), column \(column): \(reason)"
        case .raggedRow(let row, let expected, let actual):
            return "Row \(row) has \(actual) columns; expected \(expected)."
        case .invalidHeader(let reason):
            return "Spreadsheet header is invalid: \(reason)"
        }
    }
}
