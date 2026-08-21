import Foundation

public protocol RequestClassifying: Sendable {
    func classify(_ request: LumiRequest) -> RequestClassification
}

public struct HeuristicRequestClassifier: RequestClassifying, Sendable {
    public init() {}

    public func classify(_ request: LumiRequest) -> RequestClassification {
        let text = normalized(request.input)
        var capabilities: Set<LumiCapability> = [.reasoning]
        var reasons: [String] = []

        if matches(text, codingSignals) || request.profileOverride == "coding" {
            capabilities.insert(.coding)
            reasons.append(request.profileOverride == "coding" ? "coding profile override" : "coding signal")
        }

        if matches(text, reflectionSignals) || request.profileOverride == "reflection" {
            capabilities.insert(.reflection)
            reasons.append(request.profileOverride == "reflection" ? "reflection profile override" : "reflection signal")
        }

        if matches(text, fileSignals) {
            capabilities.insert(.files)
            capabilities.insert(.retrieval)
            reasons.append("file/document signal")
        }

        if matches(text, retrievalSignals) || request.profileOverride == "knowledge" {
            capabilities.insert(.retrieval)
            reasons.append(request.profileOverride == "knowledge" ? "knowledge profile override" : "retrieval signal")
        }

        if matches(text, memorySignals) {
            capabilities.insert(.memory)
            reasons.append("personal-memory signal")
        }

        if matches(text, webSignals) {
            capabilities.insert(.web)
            reasons.append("live/web signal")
        }

        if matches(text, toolSignals) {
            capabilities.insert(.tools)
            reasons.append("tool/action signal")
        }

        let risk = riskLevel(for: text, capabilities: capabilities)
        let mode: ExecutionMode
        if capabilities.contains(.tools) || capabilities.contains(.web) {
            mode = .agent
        } else if capabilities.contains(.retrieval) || capabilities.contains(.files) {
            mode = .knowledge
        } else {
            mode = .direct
        }

        let specificCapabilities = capabilities.subtracting([.reasoning]).count
        let confidence: Double
        if capabilities.contains(.tools) || risk == .high {
            confidence = 0.96
        } else if specificCapabilities >= 2 {
            confidence = 0.92
        } else if specificCapabilities == 1 {
            confidence = 0.86
        } else {
            confidence = 0.72
            reasons.append("direct fallback")
        }

        return RequestClassification(
            mode: mode,
            capabilities: capabilities,
            confidence: confidence,
            risk: risk,
            reasons: reasons
        )
    }

    private func riskLevel(for text: String, capabilities: Set<LumiCapability>) -> RiskLevel {
        if matches(text, highRiskSignals) { return .high }
        if capabilities.contains(.tools) || matches(text, mediumRiskSignals) { return .medium }
        return .low
    }

    private func normalized(_ input: String) -> String {
        input
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "`", with: "'")
    }

    private func matches(_ text: String, _ signals: [String]) -> Bool {
        signals.contains(where: text.contains)
    }

    private let codingSignals = [
        " code", "code ", "swift", "python", "javascript", "typescript", "compile", "compiler",
        "refactor", "debug", "stack trace", "api", "github", " git ", "repository", "pull request",
        "push commit", "push the commit",
        "код", "свіфт", "пайтон", "компілю", "рефактор", "дебаг", "гетхаб", "репозитор"
    ]

    private let reflectionSignals = [
        "reflect", "why did you", "self review", "review your answer", "reasoning recap",
        "рефлекс", "чому ти", "проаналізуй свою відповідь", "перевір свою відповідь"
    ]

    /// Retrieval signals are intentionally phrased as requests, rather than the bare word
    /// `search`. This avoids routing conceptual questions such as “explain binary search” into RAG.
    private let retrievalSignals = [
        "search for", "search the", "search my", "search in", "find ", "look up", "document", "manual",
        "knowledge", "what does", "according to",
        "знайди", "пошукай", "пошук у", "пошук в", "документ", "мануал", "що в документі", "згідно з"
    ]

    private let fileSignals = [
        " file", "file ", "pdf", "folder", "attachment", "uploaded", "spreadsheet", "document",
        "файл", "пдф", "pdf", "папк", "вкладення", "завантажен", "таблиц", "документ"
    ]

    private let memorySignals = [
        "remember", "recall", "memory", "preference", "prefer", "last time", "earlier i", "what did i",
        "about me", "my preference", "do i like", "did i tell",
        "запам'ят", "запам’ят", "пам'ята", "пам’ята", "пам'ять", "пам’ять", "минулого разу",
        "що я каз", "я люблю", "я віддаю перевагу", "мої вподобання"
    ]

    private let webSignals = [
        "search the web", "on the web", "internet", "online", "latest news", "breaking news", "today's news",
        "current price", "live score", "latest version", "latest release",
        "в інтернет", "у мережі", "останні новини", "актуальн", "сьогоднішні новини", "поточна ціна"
    ]

    private let toolSignals = [
        "run command", "execute command", "run the script", "open file", "open the file", "create file",
        "create a file", "delete file", "delete the file", "remove file", "rename file", "move file",
        "send email", "send message", "create repository", "create repo", "push commit", "push the commit", "merge pull request",
        "запусти команд", "виконай команд", "відкрий файл", "створи файл", "видали файл", "перейменуй файл",
        "надішли лист", "відправ лист", "створи репозитор", "запуш", "змердж"
    ]

    private let highRiskSignals = [
        "delete", "remove permanently", "erase", "format disk", "wipe", "drop database", "pay ", "purchase",
        "видали", "стерти", "очисти диск", "форматуй", "оплати", "купи "
    ]

    private let mediumRiskSignals = [
        "send email", "send message", "publish", "push commit", "push the commit", "merge pull request", "create repository",
        "write file", "rename file", "move file", "надішли", "відправ", "опублікуй", "запуш", "змердж", "створи репозитор"
    ]
}
