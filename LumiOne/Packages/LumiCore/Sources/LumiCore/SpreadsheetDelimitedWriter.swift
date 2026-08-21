import Foundation

public enum SpreadsheetFormulaInjectionPolicy: String, Codable, Sendable {
    case escapeDangerousPrefixes
}

public struct SpreadsheetExportResult: Codable, Equatable, Sendable {
    public let outputResourceID: UserFileResourceID
    public let displayName: String
    public let format: SpreadsheetFormat
    public let byteCount: Int
    public let rowCount: Int
    public let columnCount: Int
    public let neutralizedCellCount: Int

    public init(
        outputResourceID: UserFileResourceID,
        displayName: String,
        format: SpreadsheetFormat,
        byteCount: Int,
        rowCount: Int,
        columnCount: Int,
        neutralizedCellCount: Int
    ) {
        self.outputResourceID = outputResourceID
        self.displayName = displayName
        self.format = format
        self.byteCount = byteCount
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.neutralizedCellCount = neutralizedCellCount
    }
}

public protocol SpreadsheetExporter: Sendable {
    func export(
        _ snapshot: SpreadsheetTableSnapshot,
        to outputResourceID: UserFileResourceID
    ) async throws -> SpreadsheetExportResult
}

/// Deterministic CSV/TSV serializer. It never evaluates source formulas. Cells
/// that could be interpreted as formulas by spreadsheet applications are
/// neutralized before serialization.
public struct DelimitedSpreadsheetWriter: SpreadsheetWriter, SpreadsheetExporter, Sendable {
    public static let maximumOutputBytes = 16_777_216

    private let broker: any UserFileWriteBroker
    private let formulaPolicy: SpreadsheetFormulaInjectionPolicy

    public init(
        broker: any UserFileWriteBroker,
        formulaPolicy: SpreadsheetFormulaInjectionPolicy = .escapeDangerousPrefixes
    ) {
        self.broker = broker
        self.formulaPolicy = formulaPolicy
    }

    public func write(
        _ snapshot: SpreadsheetTableSnapshot,
        to outputResourceID: UserFileResourceID
    ) async throws {
        _ = try await export(snapshot, to: outputResourceID)
    }

    public func export(
        _ snapshot: SpreadsheetTableSnapshot,
        to outputResourceID: UserFileResourceID
    ) async throws -> SpreadsheetExportResult {
        let descriptor = try broker.descriptor(for: outputResourceID)
        let configuration = try outputConfiguration(displayName: descriptor.displayName)
        let serialized = serialize(
            snapshot,
            delimiter: configuration.delimiter
        )
        let byteCount = serialized.text.utf8.count
        guard byteCount <= Self.maximumOutputBytes else {
            throw SpreadsheetMutationError.outputTooLarge(byteCount)
        }

        let write = try await broker.writeText(
            resourceID: outputResourceID,
            content: serialized.text,
            requireEmpty: true
        )

        return SpreadsheetExportResult(
            outputResourceID: outputResourceID,
            displayName: write.descriptor.displayName,
            format: configuration.format,
            byteCount: write.byteCount,
            rowCount: snapshot.rowCount,
            columnCount: snapshot.columnCount,
            neutralizedCellCount: serialized.neutralizedCellCount
        )
    }

    private func outputConfiguration(
        displayName: String
    ) throws -> (format: SpreadsheetFormat, delimiter: Character) {
        let lower = displayName.lowercased()
        if lower.hasSuffix(".csv") {
            return (.csv, ",")
        }
        if lower.hasSuffix(".tsv") {
            return (.tsv, "\t")
        }
        throw SpreadsheetMutationError.unsupportedOutputFormat(displayName)
    }

    private func serialize(
        _ snapshot: SpreadsheetTableSnapshot,
        delimiter: Character
    ) -> (text: String, neutralizedCellCount: Int) {
        var lines: [String] = []
        lines.reserveCapacity(snapshot.rows.count + 1)
        var neutralizedCellCount = 0

        let header = snapshot.columns.map { escapeField($0.name, delimiter: delimiter) }
        lines.append(header.joined(separator: String(delimiter)))

        for row in snapshot.rows {
            let fields = row.cells.map { cell -> String in
                let protected = protectAgainstFormulaInjection(cell.rawValue)
                if protected != cell.rawValue {
                    neutralizedCellCount += 1
                }
                return escapeField(protected, delimiter: delimiter)
            }
            lines.append(fields.joined(separator: String(delimiter)))
        }

        return (lines.joined(separator: "\r\n") + "\r\n", neutralizedCellCount)
    }

    private func protectAgainstFormulaInjection(_ value: String) -> String {
        guard formulaPolicy == .escapeDangerousPrefixes, !value.isEmpty else {
            return value
        }

        let scalars = value.unicodeScalars
        var candidate: Unicode.Scalar?
        for scalar in scalars {
            if scalar == " " {
                continue
            }
            candidate = scalar
            break
        }

        guard let first = candidate else { return value }
        switch first.value {
        case 0x3D, // =
             0x2B, // +
             0x2D, // -
             0x40, // @
             0x09, // tab
             0x0D: // carriage return
            return "'" + value
        default:
            return value
        }
    }

    private func escapeField(_ value: String, delimiter: Character) -> String {
        let requiresQuotes = value.contains(delimiter)
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")
            || value.first?.isWhitespace == true
            || value.last?.isWhitespace == true

        guard requiresQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
