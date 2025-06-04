import Foundation

class Reflector {
    static let shared = Reflector()

    private var reflections: [String] = []
    private var lastEvaluated: String?

    private init() {}

    func observe(action: String, outcome: String) {
        let reflection = "Action: '\(action)' → Result: '\(outcome)'"
        reflections.append(reflection)
        lastEvaluated = reflection
        print("[Reflector] \(reflection)")
    }

    func latestReflection() -> String {
        return lastEvaluated ?? "No reflection available."
    }

    func summarizeReflections(limit: Int = 5) -> String {
        let recent = reflections.suffix(limit)
        return recent.joined(separator: "\n")
    }

    func reset() {
        reflections.removeAll()
        lastEvaluated = nil
    }
}
