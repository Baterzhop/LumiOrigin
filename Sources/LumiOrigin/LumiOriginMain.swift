import Foundation
import LumiCore

#if canImport(SwiftUI)
import SwiftUI

@main
struct LumiOriginApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
    }
}
#else
@main
struct LumiOriginCLI {
    static func main() async {
        let engine = LumiEngine(llm: LocalFallbackClient())
        let reply = await engine.respond(to: "Hello from Lumi")
        print(reply.message.content)
    }
}
#endif
