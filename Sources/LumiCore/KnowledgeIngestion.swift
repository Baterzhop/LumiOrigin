import Foundation

public enum KnowledgeSourceType: String, Codable, Hashable, Sendable {
    case plainText
    case markdown
    case pdf
    case unknown
}

public struct IngestibleDocument: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let content: String
    public let sourceType: KnowledgeSourceType
    public let sourceURI: String?
    public let tags: [String]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        content: String,
        sourceType: KnowledgeSourceType = .plainText,
        sourceURI: String? = nil,
        tags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.sourceType = sourceType
        self.sourceURI = sourceURI
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct KnowledgeSourceRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let sourceType: KnowledgeSourceType
    public let sourceURI: String?
    public let tags: [String]
    public let contentHash: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        title: String,
        sourceType: KnowledgeSourceType,
        sourceURI: String?,
        tags: [String],
        contentHash: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.sourceType = sourceType
        self.sourceURI = sourceURI
        self.tags = tags
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct KnowledgeChunkRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let sourceID: String
    public let ordinal: Int
    public let title: String
    public let text: String
    public let tags: [String]
    public let sourceURI: String?
    public let section: String?
    public let page: Int?
    public let contentHash: String

    public init(
        id: String,
        sourceID: String,
        ordinal: Int,
        title: String,
        text: String,
        tags: [String],
        sourceURI: String?,
        section: String?,
        page: Int? = nil,
        contentHash: String
    ) {
        self.id = id
        self.sourceID = sourceID
        self.ordinal = ordinal
        self.title = title
        self.text = text
        self.tags = tags
        self.sourceURI = sourceURI
        self.section = section
        self.page = page
        self.contentHash = contentHash
    }
}

public struct IngestionReport: Codable, Hashable, Sendable {
    public let sourceID: String
    public let contentHash: String
    public let chunkCount: Int
    public let characterCount: Int

    public init(sourceID: String, contentHash: String, chunkCount: Int, characterCount: Int) {
        self.sourceID = sourceID
        self.contentHash = contentHash
        self.chunkCount = chunkCount
        self.characterCount = characterCount
    }
}

public protocol KnowledgeRetrieving: Sendable {
    func search(_ query: String, limit: Int) async -> [KnowledgeHit]
}

public protocol KnowledgeStore: KnowledgeRetrieving {
    func replace(source: KnowledgeSourceRecord, chunks: [KnowledgeChunkRecord]) async throws
    func source(id: String) async throws -> KnowledgeSourceRecord?
    func removeSource(id: String) async throws
}

public struct StableContentHasher: Sendable {
    public init() {}

    /// Stable non-cryptographic FNV-1a hash. It is used for local deduplication/version detection,
    /// not for security or integrity guarantees.
    public func hash(_ text: String) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 1_099_511_628_211
        }
        return String(format: "%016llx", value)
    }
}

public struct TextChunker: Sendable {
    public let maxCharacters: Int
    public let overlapCharacters: Int

    public init(maxCharacters: Int = 1_200, overlapCharacters: Int = 160) {
        self.maxCharacters = max(200, maxCharacters)
        self.overlapCharacters = min(max(0, overlapCharacters), max(0, self.maxCharacters / 3))
    }

    public func chunks(for document: IngestibleDocument, hasher: StableContentHasher = StableContentHasher()) -> [KnowledgeChunkRecord] {
        let normalized = normalize(document.content)
        let sections = splitIntoSections(normalized, sourceType: document.sourceType)
        var records: [KnowledgeChunkRecord] = []

        for section in sections {
            let pieces = chunkSection(section.text)
            for piece in pieces where !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let ordinal = records.count
                let contentHash = hasher.hash(piece)
                records.append(
                    KnowledgeChunkRecord(
                        id: "\(document.id):\(ordinal):\(contentHash.prefix(8))",
                        sourceID: document.id,
                        ordinal: ordinal,
                        title: document.title,
                        text: piece,
                        tags: document.tags,
                        sourceURI: document.sourceURI,
                        section: section.title,
                        contentHash: contentHash
                    )
                )
            }
        }

        return records
    }

    private func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitIntoSections(_ text: String, sourceType: KnowledgeSourceType) -> [(title: String?, text: String)] {
        guard sourceType == .markdown else { return [(nil, text)] }

        var result: [(String?, String)] = []
        var currentTitle: String?
        var currentLines: [String] = []

        func flush() {
            let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                result.append((currentTitle, body))
            }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" || $0 == " " })
                if !heading.isEmpty {
                    flush()
                    currentLines.removeAll(keepingCapacity: true)
                    currentTitle = String(heading)
                    continue
                }
            }
            currentLines.append(rawLine)
        }
        flush()

        return result.isEmpty ? [(nil, text)] : result
    }

    private func chunkSection(_ text: String) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var current = ""

        func appendCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            chunks.append(trimmed)
        }

        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.count > maxCharacters {
                if !current.isEmpty {
                    appendCurrent()
                    current = overlapPrefix(from: current)
                }
                for piece in hardSplit(trimmed) {
                    if !current.isEmpty {
                        let candidate = current + "\n\n" + piece
                        if candidate.count <= maxCharacters {
                            current = candidate
                        } else {
                            appendCurrent()
                            current = overlapPrefix(from: current) + piece
                        }
                    } else {
                        current = piece
                    }
                }
                continue
            }

            let candidate = current.isEmpty ? trimmed : current + "\n\n" + trimmed
            if candidate.count <= maxCharacters {
                current = candidate
            } else {
                appendCurrent()
                let overlap = overlapPrefix(from: current)
                current = overlap.isEmpty ? trimmed : overlap + trimmed
            }
        }

        appendCurrent()
        return chunks
    }

    private func hardSplit(_ text: String) -> [String] {
        var pieces: [String] = []
        var remainder = text[...]

        while !remainder.isEmpty {
            let end = remainder.index(remainder.startIndex, offsetBy: min(maxCharacters, remainder.count))
            let piece = String(remainder[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            remainder = remainder[end...]
        }
        return pieces
    }

    private func overlapPrefix(from previous: String) -> String {
        guard overlapCharacters > 0, !previous.isEmpty else { return "" }
        let suffix = String(previous.suffix(overlapCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? "" : suffix + "\n"
    }
}

public struct DocumentIngestor: Sendable {
    private let chunker: TextChunker
    private let hasher: StableContentHasher

    public init(chunker: TextChunker = TextChunker(), hasher: StableContentHasher = StableContentHasher()) {
        self.chunker = chunker
        self.hasher = hasher
    }

    public func ingest(_ document: IngestibleDocument, into store: any KnowledgeStore) async throws -> IngestionReport {
        let contentHash = hasher.hash(document.content)
        let source = KnowledgeSourceRecord(
            id: document.id,
            title: document.title,
            sourceType: document.sourceType,
            sourceURI: document.sourceURI,
            tags: document.tags,
            contentHash: contentHash,
            createdAt: document.createdAt,
            updatedAt: document.updatedAt
        )
        let chunks = chunker.chunks(for: document, hasher: hasher)
        try await store.replace(source: source, chunks: chunks)

        return IngestionReport(
            sourceID: document.id,
            contentHash: contentHash,
            chunkCount: chunks.count,
            characterCount: document.content.count
        )
    }
}
