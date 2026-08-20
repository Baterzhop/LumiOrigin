import Foundation

/// Small in-memory lexical retriever kept for tests/bootstrap data.
/// Persistent document retrieval is provided by `SQLiteKnowledgeStore`.
public actor KnowledgeIndex: KnowledgeRetrieving {
    private var documents: [KnowledgeDocument]

    public init(documents: [KnowledgeDocument] = []) {
        self.documents = documents
    }

    public func replace(with documents: [KnowledgeDocument]) {
        self.documents = documents
    }

    public func add(_ document: KnowledgeDocument) {
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents[index] = document
        } else {
            documents.append(document)
        }
    }

    public func allDocuments() -> [KnowledgeDocument] {
        documents
    }

    public func search(_ query: String, limit: Int = 4) async -> [KnowledgeHit] {
        guard !documents.isEmpty else { return [] }
        let queryTokens = Self.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        let corpusTokens = documents.map {
            Self.tokenize($0.title + " " + $0.text + " " + $0.tags.joined(separator: " "))
        }
        let averageLength = Double(corpusTokens.reduce(0) { $0 + $1.count }) / Double(max(corpusTokens.count, 1))
        let n = Double(documents.count)

        var documentFrequency: [String: Int] = [:]
        for tokens in corpusTokens {
            for token in Set(tokens) {
                documentFrequency[token, default: 0] += 1
            }
        }

        let k1 = 1.5
        let b = 0.75
        var hits: [KnowledgeHit] = []

        for (index, tokens) in corpusTokens.enumerated() {
            let counts = Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +)
            var bm25 = 0.0

            for term in queryTokens {
                guard let df = documentFrequency[term], let tfInt = counts[term], tfInt > 0 else { continue }
                let tf = Double(tfInt)
                let idf = log(1.0 + (n - Double(df) + 0.5) / (Double(df) + 0.5))
                let lengthNorm = Double(tokens.count) / max(averageLength, 1.0)
                let denominator = tf + k1 * (1.0 - b + b * lengthNorm)
                bm25 += idf * (tf * (k1 + 1.0)) / max(denominator, 1e-9)
            }

            let normalized = bm25 / (1.0 + bm25)
            if normalized > 0 {
                hits.append(KnowledgeHit(document: documents[index], score: normalized))
            }
        }

        return hits
            .sorted { $0.score > $1.score }
            .prefix(max(0, limit))
            .map { $0 }
    }

    private static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 }
    }
}
