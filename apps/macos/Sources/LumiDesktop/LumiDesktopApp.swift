import AppKit
import SwiftUI

@main
struct LumiDesktopApp: App {
    @NSApplicationDelegateAdaptor(LumiApplicationDelegate.self) private var appDelegate
    @StateObject private var coreManager = CoreProcessManager.shared

    var body: some Scene {
        WindowGroup {
            LumiRootView(coreManager: coreManager)
        }
        .windowStyle(.automatic)
        .commands {
            CommandMenu("Core") {
                Button("Check / Start Lumi Core") {
                    Task { await coreManager.ensureRunning() }
                }
                Button("Restart managed Lumi Core") {
                    Task { await coreManager.restart() }
                }
            }
            CommandMenu("Developer") {
                OpenDeveloperAgentCommand()
            }
        }

        Settings {
            LumiSettingsView()
        }

        Window("Lumi Developer Agent", id: "developer-agent") {
            DeveloperAgentView()
        }
        .defaultSize(width: 900, height: 760)
    }
}

@MainActor
private final class LumiApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        CoreProcessManager.shared.stopManagedCore()
    }
}

private struct OpenDeveloperAgentCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Developer Agent…") {
            openWindow(id: "developer-agent")
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}
