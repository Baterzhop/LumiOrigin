#if canImport(SwiftUI)
import SwiftUI

@main
struct LumiOneApp: App {
    @StateObject private var model = LumiAppModel()

    var body: some Scene {
        WindowGroup("Lumi One") {
            VStack(spacing: 0) {
                if model.isTaskAvailable {
                    TaskPanel()
                    Divider()
                }
                ContentView()
            }
            .environmentObject(model)
            .frame(minWidth: 860, minHeight: 700)
        }
    }
}
#else
import Foundation

@main
enum LumiMacUnsupportedPlatform {
    static func main() {
        print("LumiMac requires macOS with SwiftUI.")
    }
}
#endif
