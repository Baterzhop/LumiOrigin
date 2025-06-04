import Foundation

class SelfCoder {
    static let shared = SelfCoder()
    
    private var codeSnippets: [String] = []
    private var versionHistory: [[String]] = []
    
    private init() {}

    func saveSnippet(_ code: String) {
        codeSnippets.append(code)
        print("[SelfCoder] Snippet saved.")
    }

    func commitVersion() {
        versionHistory.append(codeSnippets)
        codeSnippets.removeAll()
        print("[SelfCoder] Version committed.")
    }

    func latestVersion() -> [String] {
        return versionHistory.last ?? []
    }

    func diffWithPreviousVersion() -> [String] {
        guard versionHistory.count >= 2 else { return [] }
        let current = versionHistory[versionHistory.count - 1]
        let previous = versionHistory[versionHistory.count - 2]
        return current.filter { !previous.contains($0) }
    }

    func reset() {
        codeSnippets.removeAll()
        versionHistory.removeAll()
        print("[SelfCoder] Reset complete.")
    }
}
