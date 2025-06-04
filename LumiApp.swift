import Foundation

class LumiApp {
    static let shared = LumiApp()
    
    private init() {}

    func handleInput(_ input: String) {
        let intent = IntentEngine.shared.detectIntent(from: input)
        AeonCore.shared.receive(input: input)
        Reflector.shared.observe(action: input, outcome: intent)
        SelfCoder.shared.saveSnippet("Intent detected: \(intent)")
    }

    func printSummary() {
        print("===== Lumi Summary =====")
        print(AeonCore.shared.summary())
        print("Last Reflection: \(Reflector.shared.latestReflection())")
        print("Latest Version Snippets: \(SelfCoder.shared.latestVersion())")
    }
}
