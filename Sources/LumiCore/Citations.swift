import Foundation

public struct Citation: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let referenceIndex: Int
    public let sourceID: String
    public let chunkID: String
    public let title: String
    public let sourceURI: String?
    public let section: String?
    public let page: Int?
    public let excerpt: String

    public var marker: String { "S\(referenceIndex)" }

    public init(
        referenceIndex: Int,
        sourceID: String,
        chunkID: String,
        title: String,
        sourceURI: String?,
        section: String?,
        page: Int?,
        excerpt: String
    ) {
        self.id = "S\(referenceIndex):\(chunkID)"
        self.referenceIndex = referenceIndex
        self.sourceID = sourceID
        self.chunkID = chunkID
        self.title = title
        self.sourceURI = sourceURI
        self.section = section
        self.page = page
        self.excerpt = excerpt
    }
}

public struct CitationReport: Codable, Hashable, Sendable {
    public let citations: [Citation]
    public let invalidMarkers: [String]
    public let availableEvidenceCount: Int
    public let uncitedEvidenceCount: Int

    public init(
        citations: [Citation],
        invalidMarkers: [String],
        availableEvidenceCount: Int,
        uncitedEvidenceCount: Int
    ) {
        self.citations = citations
        self.invalidMarkers = invalidMarkers
        self.availableEvidenceCount = availableEvidenceCount
        self.uncitedEvidenceCount = uncitedEvidenceCount
    }

    public static let empty = CitationReport(
        citations: [],
        invalidMarkers: [],
        availableEvidenceCount: 0,
        uncitedEvidenceCount: 0
    )
}

public struct CitationAssembler: Sendable {
    public init() {}

    public func assemble(response: String, evidence: [KnowledgeHit]) -> CitationReport {
        guard !evidence.isEmpty else {
            let invalid = markers(in: response).map { "S\($0)" }
            return CitationReport(
                citations: [],
                invalidMarkers: unique(invalid),
                availableEvidenceCount: 0,
                uncitedEvidenceCount: 0
            )
        }

        let referencedIndices = markers(in: response)
        var citations: [Citation] = []
        var invalid: [String] = []
        var seenValid: Set<Int> = []
        var seenInvalid: Set<Int> = []

        for index in referencedIndices {
            guard index >= 1, index <= evidence.count else {
                if seenInvalid.insert(index).inserted {
                    invalid.append("S\(index)")
                }
                continue
            }
            guard seenValid.insert(index).inserted else { continue }

            let document = evidence[index - 1].document
            let chunkID = document.chunkID ?? document.id
            let sourceID = document.sourceID ?? document.id
            citations.append(
                Citation(
                    referenceIndex: index,
                    sourceID: sourceID,
                    chunkID: chunkID,
                    title: document.title,
                    sourceURI: document.sourceURI,
                    section: document.section,
                    page: document.page,
                    excerpt: Self.preview(document.text)
                )
            )
        }

        return CitationReport(
            citations: citations,
            invalidMarkers: invalid,
            availableEvidenceCount: evidence.count,
            uncitedEvidenceCount: max(0, evidence.count - seenValid.count)
        )
    }

    private func markers(in text: String) -> [Int] {
        let pattern = #"\[S([0-9]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let valueRange = Range(match.range(at: 1), in: text)
            else { return nil }
            return Int(text[valueRange])
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func preview(_ text: String, limit: Int = 280) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }
}
