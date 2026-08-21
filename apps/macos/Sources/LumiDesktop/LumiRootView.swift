import SwiftUI

struct LumiRootView: View {
    @ObservedObject var coreManager: CoreProcessManager
    @State private var allowOfflineUI = false

    var body: some View {
        Group {
            switch coreManager.state {
            case .connected, .runningManaged:
                ContentView()
            case .checking, .starting:
                startupView
            case .runtimeMissing:
                problemView(
                    title: "Lumi Core is not installed",
                    message: coreManager.detail,
                    canContinue: false
                )
            case .remoteUnavailable:
                if allowOfflineUI { ContentView() } else {
                    problemView(
                        title: "Configured Lumi Core is unavailable",
                        message: coreManager.detail,
                        canContinue: true
                    )
                }
            case .failed:
                if allowOfflineUI { ContentView() } else {
                    problemView(
                        title: "Lumi Core could not start",
                        message: coreManager.detail,
                        canContinue: true
                    )
                }
            }
        }
        .task {
            await coreManager.ensureRunning()
        }
    }

    private var startupView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Starting Lumi")
                .font(.title2.weight(.semibold))
            Text(coreManager.detail)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private func problemView(title: String, message: String, canContinue: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 38))
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            HStack {
                Button("Retry") {
                    Task { await coreManager.ensureRunning() }
                }
                .buttonStyle(.borderedProminent)
                if canContinue {
                    Button("Open UI offline") {
                        allowOfflineUI = true
                    }
                }
            }
            if !canContinue {
                Text("Install Lumi from the repository with: bash scripts/install_lumi.sh")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding(30)
        .frame(minWidth: 760, minHeight: 520)
    }
}
