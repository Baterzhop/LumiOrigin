import Foundation

public enum SpreadsheetFilterOperator: String, Codable, CaseIterable, Sendable {
    case equals
    case notEquals
    case contains
    case startsWith
    case endsWith
    case isEmpty
    case isNotEmpty
    case numericGreaterThan
    case numericGreaterThanOrEqual
    case numericLessThan
    case numericLessThanOrEqual
}

public enum SpreadsheetSortDirection: String, Codable, CaseIterable, Sendable {
    case ascending
    case descending
}

public enum SpreadsheetSortMode: String, Codable, CaseIterable, Sendable {
    case text
    case numeric
}

public struct SpreadsheetFilterSpec: Codable, Equatable, Sendable {
    public let column: String
    public let operation: SpreadsheetFilterOperator
    public let value: String?
    public let caseSensitive: Bool

    public init(
        column: String,
        operation: SpreadsheetFilterOperator,
        value: String? = nil,
        caseSensitive: Bool = false
    ) {
        self.column = column
        self.operation = operation
        self.value = value
        self.caseSensitive = caseSensitive
    }
}

public struct SpreadsheetSortSpec: Codable, Equatable, Sendable {
    public let column: String
    public let direction: SpreadsheetSortDirection
    public let mode: SpreadsheetSortMode

    public init(
        column: String,
        direction: SpreadsheetSortDirection = .ascending,
        mode: SpreadsheetSortMode = .text
    ) {
        self.column = column
        self.direction = direction
        self.mode = mode
    }
}

public struct SpreadsheetTransformSpec: Codable, Equatable, Sendable {
    public let selectedColumns: [String]?
    public let filter: SpreadsheetFilterSpec?
    public let sort: SpreadsheetSortSpec?

    public init(
        selectedColumns: [String]? = nil,
        filter: SpreadsheetFilterSpec? = nil,
        sort: SpreadsheetSortSpec? = nil
    ) {
        self.selectedColumns = selectedColumns
        self.filter = filter
        self.sort = sort
    }
}

public struct SpreadsheetTransformResult: Equatable, Sendable {
    public let snapshot: SpreadsheetTableSnapshot
    /// Maps transformed row position back to the original parsed source row.
    public let sourceRowIndices: [Int]

    public init(snapshot: SpreadsheetTableSnapshot, sourceRowIndices: [Int]) {
        self.snapshot = snapshot
        self.sourceRowIndices = sourceRowIndices
    }
}

public struct SpreadsheetTransformEngine: Sendable {
    public init() {}

    public func apply(
        _ spec: SpreadsheetTransformSpec,
        to source: SpreadsheetTableSnapshot
    ) throws -> SpreadsheetTransformResult {
        guard !source.columns.isEmpty else {
            throw SpreadsheetMutationError.invalidTransform("source has no columns")
        }

        let columnsByName = Dictionary(uniqueKeysWithValues: source.columns.map { ($0.name, $0) })
        let selectedSourceColumns: [SpreadsheetColumn]
        if let selected = spec.selectedColumns {
            guard !selected.isEmpty else {
                throw SpreadsheetMutationError.invalidTransform("selectedColumns cannot be empty")
            }
            guard Set(selected).count == selected.count else {
                throw SpreadsheetMutationError.invalidTransform("selectedColumns contains duplicates")
            }
            selectedSourceColumns = try selected.map { name in
                guard let column = columnsByName[name] else {
                    throw SpreadsheetMutationError.unknownColumn(name)
                }
                return column
            }
        } else {
            selectedSourceColumns = source.columns
        }

        var working = source.rows

        if let filter = spec.filter {
            guard let column = columnsByName[filter.column] else {
                throw SpreadsheetMutationError.unknownColumn(filter.column)
            }
            try validate(filter)
            working = try working.filter { row in
                try matches(
                    raw: row.cells[column.index].rawValue,
                    filter: filter
                )
            }
        }

        if let sort = spec.sort {
            guard let column = columnsByName[sort.column] else {
                throw SpreadsheetMutationError.unknownColumn(sort.column)
            }
            working.sort { lhs, rhs in
                let comparison = compare(
                    lhs.cells[column.index].rawValue,
                    rhs.cells[column.index].rawValue,
                    mode: sort.mode
                )
                if comparison == .orderedSame {
                    return lhs.index < rhs.index
                }
                switch sort.direction {
                case .ascending:
                    return comparison == .orderedAscending
                case .descending:
                    return comparison == .orderedDescending
                }
            }
        }

        let sourceRowIndices = working.map(\.index)
        let transformedColumns = selectedSourceColumns.enumerated().map { offset, sourceColumn in
            SpreadsheetColumn(index: offset, name: sourceColumn.name)
        }
        let transformedRows = working.enumerated().map { rowOffset, sourceRow in
            SpreadsheetRow(
                index: rowOffset + 1,
                cells: selectedSourceColumns.map { sourceRow.cells[$0.index] }
            )
        }

        let transformed = SpreadsheetTableSnapshot(
            resourceID: source.resourceID,
            displayName: source.displayName,
            format: source.format,
            tableID: SpreadsheetTableID(rawValue: source.tableID.rawValue + ":transform"),
            columns: transformedColumns,
            rows: transformedRows,
            sourceByteCount: source.sourceByteCount
        )
        return SpreadsheetTransformResult(
            snapshot: transformed,
            sourceRowIndices: sourceRowIndices
        )
    }

    private func validate(_ filter: SpreadsheetFilterSpec) throws {
        switch filter.operation {
        case .isEmpty, .isNotEmpty:
            return
        default:
            guard let value = filter.value else {
                throw SpreadsheetMutationError.invalidTransform(
                    "filter operation \(filter.operation.rawValue) requires value"
                )
            }
            if isNumeric(filter.operation), Double(value) == nil {
                throw SpreadsheetMutationError.invalidTransform(
                    "numeric filter value must be a finite number"
                )
            }
        }
    }

    private func matches(raw: String, filter: SpreadsheetFilterSpec) throws -> Bool {
        switch filter.operation {
        case .isEmpty:
            return raw.isEmpty
        case .isNotEmpty:
            return !raw.isEmpty
        case .equals, .notEquals, .contains, .startsWith, .endsWith:
            let expected = filter.value ?? ""
            let lhs = filter.caseSensitive ? raw : raw.lowercased()
            let rhs = filter.caseSensitive ? expected : expected.lowercased()
            switch filter.operation {
            case .equals: return lhs == rhs
            case .notEquals: return lhs != rhs
            case .contains: return lhs.contains(rhs)
            case .startsWith: return lhs.hasPrefix(rhs)
            case .endsWith: return lhs.hasSuffix(rhs)
            default: return false
            }
        case .numericGreaterThan,
             .numericGreaterThanOrEqual,
             .numericLessThan,
             .numericLessThanOrEqual:
            guard
                let expectedText = filter.value,
                let expected = Double(expectedText), expected.isFinite,
                let actual = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                actual.isFinite
            else {
                return false
            }
            switch filter.operation {
            case .numericGreaterThan: return actual > expected
            case .numericGreaterThanOrEqual: return actual >= expected
            case .numericLessThan: return actual < expected
            case .numericLessThanOrEqual: return actual <= expected
            default: return false
            }
        }
    }

    private func isNumeric(_ operation: SpreadsheetFilterOperator) -> Bool {
        switch operation {
        case .numericGreaterThan,
             .numericGreaterThanOrEqual,
             .numericLessThan,
             .numericLessThanOrEqual:
            return true
        default:
            return false
        }
    }

    private func compare(
        _ lhs: String,
        _ rhs: String,
        mode: SpreadsheetSortMode
    ) -> ComparisonResult {
        switch mode {
        case .text:
            return lhs.compare(rhs, options: [.caseInsensitive, .literal])
        case .numeric:
            let left = Double(lhs.trimmingCharacters(in: .whitespacesAndNewlines))
            let right = Double(rhs.trimmingCharacters(in: .whitespacesAndNewlines))
            switch (left, right) {
            case let (.some(a), .some(b)) where a.isFinite && b.isFinite:
                if a < b { return .orderedAscending }
                if a > b { return .orderedDescending }
                return .orderedSame
            case (.some, .none):
                return .orderedAscending
            case (.none, .some):
                return .orderedDescending
            default:
                return lhs.compare(rhs, options: [.caseInsensitive, .literal])
            }
        }
    }
}

public struct SpreadsheetMutationPlan: Sendable {
    public let token: String
    public let sourceResourceID: UserFileResourceID
    public let outputResourceID: UserFileResourceID
    public let spec: SpreadsheetTransformSpec
    public let transformed: SpreadsheetTableSnapshot
    public let sourceRowIndices: [Int]
    public let createdAt: Date

    public init(
        token: String,
        sourceResourceID: UserFileResourceID,
        outputResourceID: UserFileResourceID,
        spec: SpreadsheetTransformSpec,
        transformed: SpreadsheetTableSnapshot,
        sourceRowIndices: [Int],
        createdAt: Date = Date()
    ) {
        self.token = token
        self.sourceResourceID = sourceResourceID
        self.outputResourceID = outputResourceID
        self.spec = spec
        self.transformed = transformed
        self.sourceRowIndices = sourceRowIndices
        self.createdAt = createdAt
    }
}

/// Ephemeral, process-local plans deliberately prevent a write from being
/// reinterpreted after approval. The write tool serializes the exact immutable
/// transformed snapshot that the preview tool produced.
public final class SpreadsheetMutationPlanStore: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [String: SpreadsheetMutationPlan] = [:]
    private let maximumPlans: Int

    public init(maximumPlans: Int = 32) {
        self.maximumPlans = max(1, maximumPlans)
    }

    @discardableResult
    public func store(
        sourceResourceID: UserFileResourceID,
        outputResourceID: UserFileResourceID,
        spec: SpreadsheetTransformSpec,
        result: SpreadsheetTransformResult
    ) -> SpreadsheetMutationPlan {
        let token = UUID().uuidString.lowercased()
        let plan = SpreadsheetMutationPlan(
            token: token,
            sourceResourceID: sourceResourceID,
            outputResourceID: outputResourceID,
            spec: spec,
            transformed: result.snapshot,
            sourceRowIndices: result.sourceRowIndices
        )

        lock.withLock {
            if plans.count >= maximumPlans,
               let oldest = plans.values.min(by: { $0.createdAt < $1.createdAt }) {
                plans.removeValue(forKey: oldest.token)
            }
            plans[token] = plan
        }
        return plan
    }

    public func plan(token: String) throws -> SpreadsheetMutationPlan {
        guard let plan = lock.withLock({ plans[token] }) else {
            throw SpreadsheetMutationError.planNotFound
        }
        return plan
    }

    public func consume(token: String) {
        _ = lock.withLock {
            plans.removeValue(forKey: token)
        }
    }

    public func removeAll() {
        lock.withLock { plans.removeAll() }
    }
}

public enum SpreadsheetMutationError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalidTransform(String)
    case unknownColumn(String)
    case sourceEqualsOutput
    case planNotFound
    case unsupportedOutputFormat(String)
    case outputTooLarge(Int)

    public var description: String {
        switch self {
        case .invalidTransform(let detail):
            return "Invalid spreadsheet transform: \(detail)."
        case .unknownColumn(let name):
            return "Spreadsheet column not found: \(name)."
        case .sourceEqualsOutput:
            return "Spreadsheet output must be a different user-file resource from the source."
        case .planNotFound:
            return "Spreadsheet mutation preview is missing or expired. Preview the exact transform again before writing."
        case .unsupportedOutputFormat(let name):
            return "Unsupported spreadsheet output format for \(name); Phase 8 writes CSV or TSV only."
        case .outputTooLarge(let bytes):
            return "Spreadsheet output is too large (\(bytes) bytes)."
        }
    }
}
