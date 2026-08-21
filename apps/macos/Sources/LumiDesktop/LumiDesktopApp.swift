import SwiftUI

@main
struct LumiDesktopApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .commands {
            CommandMenu("Developer") {
                OpenDeveloperAgentCommand()
            }
        }

        Window("Lumi Developer Agent", id: "developer-agent") {
            DeveloperAgentView()
        }
        .defaultSize(width: 900, height: 760)
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
