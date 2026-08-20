import Foundation

public struct VectorRecord: Sendable {
    public let chunk: KnowledgeChunkRecord
    public let modelID: String
    public let vector: [Float]

    public init(chunk: KnowledgeChunkRecord, modelID: String, vector: [Float]) {
        self.chunk = chunk
        self.modelID = modelID
        self.vector = vector
    }
}

public protocol VectorIndex: Sendable {
    func replace(sourceID: String, records: [VectorRecord]) async throws
    func removeSource(id: String) async throws
    func search(vector: [Float], modelID: String, limit: Int) async throws -> [KnowledgeHit]
}

public enum VectorIndexError: Error, LocalizedError, Sendable {
    case emptyVector
    case dimensionMismatch
    case invalidVector
    case openFailed(String)
    case migrationFailed(String)
    case statementFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyVector: return "The vector is empty."
        case .dimensionMismatch: return "Vector dimensions do not match."
        case .invalidVector: return "The vector contains invalid values."
        case .openFailed(let detail): return "Could not open the vector database: \(detail)"
        case .migrationFailed(let detail): return "Could not migrate the vector database: \(detail)"
        case .statementFailed(let detail): return "Vector database statement failed: \(detail)"
        case .writeFailed(let detail): return "Could not write vector data: \(detail)"
        }
    }
}

public enum VectorMath {
    public static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) throws -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { throw VectorIndexError.emptyVector }
        guard lhs.count == rhs.count else { throw VectorIndexError.dimensionMismatch }
        guard lhs.allSatisfy({ $0.isFinite }), rhs.allSatisfy({ $0.isFinite }) else {
            throw VectorIndexError.invalidVector
        }

        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0

        for index in lhs.indices {
            let a = Double(lhs[index])
            let b = Double(rhs[index])
            dot += a * b
            lhsNorm += a * a
            rhsNorm += b * b
        }

        guard lhsNorm > 0, rhsNorm > 0 else { return 0 }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }
}
