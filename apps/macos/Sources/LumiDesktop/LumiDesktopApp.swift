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
                Divider()
                OpenReadinessCommand()
                OpenDiagnosticsCommand()
            }
            CommandMenu("Developer") {
                OpenDeveloperAgentCommand()
            }
        }

        Settings {
            LumiSettingsView()
        }

        Window("Lumi Readiness Center", id: "readiness") {
            LumiReadinessView(coreManager: coreManager)
        }
        .defaultSize(width: 800, height: 660)

        Window("Lumi Diagnostics", id: "diagnostics") {
            LumiDiagnosticsView(coreManager: coreManager)
        }
        .defaultSize(width: 760, height: 560)

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

private struct OpenReadinessCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Readiness Center…") {
            openWindow(id: "readiness")
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }
}

private struct OpenDiagnosticsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Diagnostics…") {
            openWindow(id: "diagnostics")
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
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
