#if canImport(SwiftUI)
import SwiftUI

@main
struct LumiOneApp: App {
    @StateObject private var model = LumiAppModel()

    var body: some Scene {
        WindowGroup("Lumi One") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 560)
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
