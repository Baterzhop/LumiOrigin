import Foundation

public struct KnowledgeChunker: Sendable {
    public struct Configuration: Equatable, Sendable {
        public let maxCharacters: Int
        public let overlapCharacters: Int

        public init(
            maxCharacters: Int = 1_800,
            overlapCharacters: Int = 180
        ) throws {
            guard (256...16_384).contains(maxCharacters) else {
                throw KnowledgeChunkingError.invalidMaximum
            }
            guard overlapCharacters >= 0, overlapCharacters < maxCharacters else {
                throw KnowledgeChunkingError.invalidOverlap
            }
            self.maxCharacters = maxCharacters
            self.overlapCharacters = overlapCharacters
        }
    }

    private struct Token: Sendable {
        let pageNumber: Int
        let text: String
    }

    public let configuration: Configuration

    public init(configuration: Configuration? = nil) {
        if let configuration {
            self.configuration = configuration
        } else {
            // Constants above are known-valid; this fallback cannot fail.
            self.configuration = try! Configuration()
        }
    }

    public func chunk(
        _ extracted: ExtractedDocument,
        documentID: UUID
    ) throws -> [KnowledgeChunk] {
        try validatePages(extracted.pages)

        var tokens: [Token] = []
        for page in extracted.pages {
            let words = page.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            for word in words where !word.isEmpty {
                tokens.append(contentsOf: splitLongToken(word, pageNumber: page.pageNumber))
            }
        }

        guard !tokens.isEmpty else { return [] }

        var chunks: [KnowledgeChunk] = []
        var start = 0
        var ordinal = 0

        while start < tokens.count {
            var end = start
            var characterCount = 0

            while end < tokens.count {
                let tokenLength = tokens[end].text.count
                let separatorLength = end == start ? 0 : 1
                let candidateLength = characterCount + separatorLength + tokenLength

                if end > start, candidateLength > configuration.maxCharacters {
                    break
                }

                characterCount = candidateLength
                end += 1

                if characterCount >= configuration.maxCharacters {
                    break
                }
            }

            guard end > start else {
                throw KnowledgeChunkingError.noProgress
            }

            let slice = tokens[start..<end]
            let text = slice.map(\.text).joined(separator: " ")
            let firstPage = slice.first!.pageNumber
            let lastPage = slice.last!.pageNumber

            chunks.append(
                KnowledgeChunk(
                    documentID: documentID,
                    ordinal: ordinal,
                    pageStart: firstPage,
                    pageEnd: lastPage,
                    text: text
                )
            )
            ordinal += 1

            guard end < tokens.count else { break }

            let overlapCount = trailingOverlapTokenCount(in: Array(slice))
            // Always advance by at least one source token, even when a very short
            // chunk fits entirely inside the configured overlap window.
            start = max(start + 1, end - overlapCount)
        }

        return chunks
    }

    private func validatePages(_ pages: [ExtractedDocumentPage]) throws {
        guard !pages.isEmpty else {
            throw KnowledgeIngestionError.emptyDocument
        }

        var previous = 0
        for page in pages {
            guard page.pageNumber > previous, page.pageNumber > 0 else {
                throw KnowledgeIngestionError.invalidPageOrder
            }
            previous = page.pageNumber
        }
    }

    private func splitLongToken(_ token: String, pageNumber: Int) -> [Token] {
        guard token.count > configuration.maxCharacters else {
            return [Token(pageNumber: pageNumber, text: token)]
        }

        var output: [Token] = []
        var index = token.startIndex
        while index < token.endIndex {
            let end = token.index(
                index,
                offsetBy: configuration.maxCharacters,
                limitedBy: token.endIndex
            ) ?? token.endIndex
            output.append(Token(pageNumber: pageNumber, text: String(token[index..<end])))
            index = end
        }
        return output
    }

    private func trailingOverlapTokenCount(in tokens: [Token]) -> Int {
        guard configuration.overlapCharacters > 0, tokens.count > 1 else {
            return 0
        }

        var count = 0
        var characters = 0

        for token in tokens.reversed() {
            let separator = count == 0 ? 0 : 1
            let candidate = characters + separator + token.text.count
            guard candidate <= configuration.overlapCharacters else { break }
            characters = candidate
            count += 1
        }

        return min(count, tokens.count - 1)
    }
}

public enum KnowledgeChunkingError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalidMaximum
    case invalidOverlap
    case noProgress

    public var description: String {
        switch self {
        case .invalidMaximum:
            return "Knowledge chunk maximum must be between 256 and 16384 characters."
        case .invalidOverlap:
            return "Knowledge chunk overlap must be non-negative and smaller than the maximum."
        case .noProgress:
            return "Knowledge chunking could not make forward progress."
        }
    }
}
