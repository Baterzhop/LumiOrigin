import Foundation

/// Strict, deterministic CSV/TSV reader. It never executes formulas and never
/// infers numeric/boolean types from delimited text: source fields remain text.
public struct DelimitedSpreadsheetReader: SpreadsheetReader, Sendable {
    private let broker: any UserFileAccessBroker

    public init(broker: any UserFileAccessBroker = UnavailableUserFileAccessBroker()) {
        self.broker = broker
    }

    public func read(_ request: SpreadsheetReadRequest) async throws -> SpreadsheetTableSnapshot {
        try validate(request)
        let descriptor = try broker.descriptor(for: request.resourceID)
        let delimiter = try resolveDelimiter(request.delimiter, displayName: descriptor.displayName)
        let format: SpreadsheetFormat = delimiter == "\t" ? .tsv : .csv

        let read = try await broker.readText(
            resourceID: request.resourceID,
            maxBytes: request.maxBytes
        )
        guard !read.truncated else {
            throw SpreadsheetError.inputTooLarge(maxBytes: request.maxBytes)
        }

        let recordLimit = request.maxRows + (request.headerMode == .firstRow ? 1 : 0)
        var rawRows = try Self.parse(
            read.content,
            delimiter: delimiter,
            maxRecords: recordLimit,
            maxColumns: request.maxColumns
        )

        guard !rawRows.isEmpty else { throw SpreadsheetError.emptyTable }
        if !rawRows[0].isEmpty {
            rawRows[0][0] = Self.removingUTF8BOM(rawRows[0][0])
        }

        let expectedColumns = rawRows[0].count
        guard expectedColumns > 0 else { throw SpreadsheetError.emptyTable }
        for (offset, row) in rawRows.enumerated() where row.count != expectedColumns {
            throw SpreadsheetError.raggedRow(
                row: offset + 1,
                expectedColumns: expectedColumns,
                actualColumns: row.count
            )
        }

        let columns: [SpreadsheetColumn]
        let dataRows: [[String]]
        switch request.headerMode {
        case .firstRow:
            let header = rawRows.removeFirst()
            columns = try Self.makeHeaderColumns(header)
            dataRows = rawRows
        case .none:
            columns = (0..<expectedColumns).map {
                SpreadsheetColumn(index: $0, name: "column_\($0 + 1)")
            }
            dataRows = rawRows
        }

        guard !dataRows.isEmpty else { throw SpreadsheetError.emptyTable }
        let containsAnyData = dataRows.contains { row in
            row.contains { !$0.isEmpty }
        }
        guard containsAnyData else { throw SpreadsheetError.emptyTable }

        let rows = dataRows.enumerated().map { offset, rawRow in
            SpreadsheetRow(
                index: offset + 1,
                cells: rawRow.map(SpreadsheetCell.losslessDelimitedText)
            )
        }

        return SpreadsheetTableSnapshot(
            resourceID: request.resourceID,
            displayName: descriptor.displayName,
            format: format,
            tableID: SpreadsheetTableID(rawValue: "table:0"),
            columns: columns,
            rows: rows,
            sourceByteCount: read.byteCount
        )
    }

    private func validate(_ request: SpreadsheetReadRequest) throws {
        guard (1...16_777_216).contains(request.maxBytes) else {
            throw SpreadsheetError.invalidReadLimit("maxBytes must be between 1 byte and 16 MiB")
        }
        guard (1...100_000).contains(request.maxRows) else {
            throw SpreadsheetError.invalidReadLimit("maxRows must be between 1 and 100000")
        }
        guard (1...2_048).contains(request.maxColumns) else {
            throw SpreadsheetError.invalidReadLimit("maxColumns must be between 1 and 2048")
        }
    }

    private func resolveDelimiter(
        _ requested: DelimitedTextDelimiter,
        displayName: String
    ) throws -> Character {
        if let explicit = requested.character { return explicit }

        let lower = displayName.lowercased()
        if lower.hasSuffix(".csv") { return "," }
        if lower.hasSuffix(".tsv") { return "\t" }
        throw SpreadsheetError.unsupportedFormat(displayName)
    }

    private static func makeHeaderColumns(_ header: [String]) throws -> [SpreadsheetColumn] {
        var seen: Set<String> = []
        var columns: [SpreadsheetColumn] = []

        for (index, sourceName) in header.enumerated() {
            let name = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw SpreadsheetError.invalidHeader("column \(index + 1) has an empty name")
            }
            let identity = name.lowercased()
            guard seen.insert(identity).inserted else {
                throw SpreadsheetError.invalidHeader("duplicate column name \(name)")
            }
            columns.append(SpreadsheetColumn(index: index, name: name))
        }
        return columns
    }

    private static func removingUTF8BOM(_ value: String) -> String {
        guard value.unicodeScalars.first?.value == 0xFEFF else { return value }
        return String(value.unicodeScalars.dropFirst())
    }

    private enum ParseState {
        case unquoted
        case quoted
        case afterQuote
    }

    /// RFC-4180-style state machine with strict quote placement. Line endings are
    /// normalized to LF before parsing; embedded quoted line breaks stay embedded.
    static func parse(
        _ source: String,
        delimiter: Character,
        maxRecords: Int,
        maxColumns: Int
    ) throws -> [[String]] {
        guard !source.isEmpty else { return [] }

        let text = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var state: ParseState = .unquoted
        var endedWithRecordSeparator = false

        func currentCoordinates() -> (Int, Int) {
            (rows.count + 1, row.count + 1)
        }

        func appendField() throws {
            guard row.count < maxColumns else {
                throw SpreadsheetError.columnLimitExceeded(maxColumns: maxColumns)
            }
            row.append(field)
            field.removeAll(keepingCapacity: true)
        }

        func appendRow() throws {
            try appendField()
            guard rows.count < maxRecords else {
                throw SpreadsheetError.rowLimitExceeded(maxRows: maxRecords)
            }
            rows.append(row)
            row.removeAll(keepingCapacity: true)
        }

        for character in text {
            switch state {
            case .quoted:
                endedWithRecordSeparator = false
                if character == "\"" {
                    state = .afterQuote
                } else {
                    field.append(character)
                }

            case .afterQuote:
                if character == "\"" {
                    field.append("\"")
                    state = .quoted
                    endedWithRecordSeparator = false
                } else if character == delimiter {
                    try appendField()
                    state = .unquoted
                    endedWithRecordSeparator = false
                } else if character == "\n" {
                    try appendRow()
                    state = .unquoted
                    endedWithRecordSeparator = true
                } else {
                    let coordinates = currentCoordinates()
                    throw SpreadsheetError.malformedDelimitedText(
                        row: coordinates.0,
                        column: coordinates.1,
                        reason: "unexpected character after a closing quote"
                    )
                }

            case .unquoted:
                if character == delimiter {
                    try appendField()
                    endedWithRecordSeparator = false
                } else if character == "\n" {
                    try appendRow()
                    endedWithRecordSeparator = true
                } else if character == "\"" {
                    guard field.isEmpty else {
                        let coordinates = currentCoordinates()
                        throw SpreadsheetError.malformedDelimitedText(
                            row: coordinates.0,
                            column: coordinates.1,
                            reason: "quote must begin at the start of a field"
                        )
                    }
                    state = .quoted
                    endedWithRecordSeparator = false
                } else {
                    field.append(character)
                    endedWithRecordSeparator = false
                }
            }
        }

        if state == .quoted {
            let coordinates = currentCoordinates()
            throw SpreadsheetError.malformedDelimitedText(
                row: coordinates.0,
                column: coordinates.1,
                reason: "unterminated quoted field"
            )
        }

        if !endedWithRecordSeparator || !row.isEmpty || !field.isEmpty || state == .afterQuote {
            try appendRow()
        }
        return rows
    }
}
