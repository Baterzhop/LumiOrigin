import Foundation

public struct IntentRouter: Sendable {
    public init() {}

    public func detect(_ input: String) -> LumiIntent {
        let text = input.lowercased()

        let coding = [
            "code", "swift", "python", "bug", "compile", "refactor", "api", "git",
            "код", "свіфт", "пайтон", "помилка", "компілю", "рефактор", "гит", "github"
        ]
        if coding.contains(where: text.contains) { return .coding }

        let tool = [
            "run ", "execute ", "open ", "delete ", "create file", "запусти", "виконай", "відкрий", "видали", "створи файл"
        ]
        if tool.contains(where: text.contains) { return .tool }

        let reflection = [
            "reflect", "why did you", "summarize our", "self review", "рефлекс", "чому ти", "підсумуй нашу", "проаналізуй себе"
        ]
        if reflection.contains(where: text.contains) { return .reflection }

        let knowledge = [
            "search", "find", "document", "manual", "knowledge", "what does", "знайди", "пошук", "документ", "мануал", "що в документі"
        ]
        if knowledge.contains(where: text.contains) { return .knowledge }

        return .chat
    }
}
