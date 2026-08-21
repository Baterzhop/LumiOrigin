import AppKit
import SwiftUI
import LumiClientCore

struct LumiDiagnosticsView: View {
    @ObservedObject var coreManager: CoreProcessManager
    @State private var report = "Collecting diagnostics…"
    @State private var isRefreshing = false

    private let fileManager = FileManager.default

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lumi Diagnostics")
                        .font(.title2.weight(.semibold))
                    Text("Safe support information only. API keys, prompts and document contents are never included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isRefreshing { ProgressView().controlSize(.small) }
            }

            ScrollView {
                Text(report)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("Refresh") {
                    Task { await refresh() }
                }
                .disabled(isRefreshing)

                Button("Copy diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }

                Spacer()

                Button("Open Core log") {
                    revealOrOpen(logURL)
                }
                Button("Open data folder") {
                    openDirectory(dataDirectoryURL)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 500)
        .task { await refresh() }
    }

    @MainActor
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let client = LumiClientConfiguration.configuredClient()
        let runtimeURL = CoreProcessManager.findCoreExecutable()?.path ?? "not found"
        let keyState = LumiClientConfiguration.hasStoredAPIKey() ? "stored in Keychain" : "not stored"
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"

        var lines: [String] = [
            "Lumi diagnostics",
            "================",
            "App version: \(appVersion)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(architectureName)",
            "Core manager: \(stateName(coreManager.state))",
            "Core detail: \(coreManager.detail)",
            "Core URL: \(client.baseURL.absoluteString)",
            "API key: \(keyState)",
            "Runtime executable: \(runtimeURL)",
            "Data directory: \(dataDirectoryURL.path)",
            "Core log: \(logURL.path)",
        ]

        do {
            let health = try await client.health()
            lines.append("Core health: ok=\(health.ok) version=\(health.version)")
        } catch {
            lines.append("Core health: unavailable (\(safeError(error)))")
        }

        do {
            let runtime = try await client.runtimeStatus()
            let semanticState = runtime.memory?.semanticEnabled == true ? "enabled" : "disabled"
            lines.append("Runtime: ok=\(runtime.ok) provider=\(runtime.provider) model=\(runtime.model)")
            lines.append("Registered tools: \(runtime.tools?.count ?? 0)")
            lines.append("Memory semantic retrieval: \(semanticState)")
        } catch {
            lines.append("Runtime metadata: unavailable (\(safeError(error)))")
        }

        lines.append("")
        lines.append("No API key values, chat text, memory contents, repository contents or knowledge-document contents are included in this report.")
        report = lines.joined(separator: "\n")
    }

    private var applicationSupportURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lumi", isDirectory: true)
    }

    private var dataDirectoryURL: URL {
        applicationSupportURL.appendingPathComponent("data", isDirectory: true)
    }

    private var logURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Lumi/core.log")
    }

    private var architectureName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func stateName(_ state: CoreProcessManager.State) -> String {
        switch state {
        case .checking: return "checking"
        case .connected: return "connected"
        case .starting: return "starting"
        case .runningManaged: return "running-managed"
        case .remoteUnavailable: return "remote-unavailable"
        case .runtimeMissing: return "runtime-missing"
        case .failed: return "failed"
        }
    }

    private func safeError(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.count <= 240 ? text : String(text.prefix(240)) + "…"
    }

    private func revealOrOpen(_ url: URL) {
        if fileManager.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            openDirectory(url.deletingLastPathComponent())
        }
    }

    private func openDirectory(_ url: URL) {
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
