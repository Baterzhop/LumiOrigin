import Foundation

public enum GroundedCitationError: Error, CustomStringConvertible, Sendable, Equatable {
    case unknownLabels([String])

    public var description: String {
        switch self {
        case .unknownLabels(let labels):
            return "Model returned unknown grounded citation labels: \(labels.joined(separator: ", "))."
        }
    }
}

/// Resolves citation markers such as `[K1]` only against the exact context
/// snapshot supplied for the current model turn. Unknown labels fail closed so
/// a hallucinated marker can never be surfaced as a trusted Knowledge citation.
public struct GroundedCitationResolver: Sendable {
    public init() {}

    public func resolve(
        in answer: String,
        context: GroundedContext?
    ) throws -> [KnowledgeCitation] {
        let labels = Self.labels(in: answer)
        guard !labels.isEmpty else { return [] }

        let available = Dictionary(
            uniqueKeysWithValues: (context?.entries ?? []).map {
                ($0.citation.label, $0.citation)
            }
        )

        var citations: [KnowledgeCitation] = []
        var seen: Set<String> = []
        var unknown: [String] = []

        for label in labels where seen.insert(label).inserted {
            if let citation = available[label] {
                citations.append(citation)
            } else {
                unknown.append(label)
            }
        }

        guard unknown.isEmpty else {
            throw GroundedCitationError.unknownLabels(unknown)
        }
        return citations
    }

    static func labels(in text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var labels: [String] = []
        var index = 0

        while index < scalars.count {
            guard scalars[index] == "[" else {
                index += 1
                continue
            }

            var cursor = index + 1
            guard cursor < scalars.count, scalars[cursor] == "K" else {
                index += 1
                continue
            }
            cursor += 1

            let digitStart = cursor
            while cursor < scalars.count,
                  CharacterSet.decimalDigits.contains(scalars[cursor]) {
                cursor += 1
            }

            guard cursor > digitStart,
                  cursor < scalars.count,
                  scalars[cursor] == "]"
            else {
                index += 1
                continue
            }

            let label = String(String.UnicodeScalarView(scalars[(index + 1)..<cursor]))
            labels.append(label)
            index = cursor + 1
        }

        return labels
    }
}
