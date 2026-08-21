import AppKit
import Foundation
import LumiClientCore

@MainActor
final class CoreProcessManager: ObservableObject {
    static let shared = CoreProcessManager()

    enum State: Equatable {
        case checking
        case connected
        case starting
        case runningManaged
        case remoteUnavailable(String)
        case runtimeMissing
        case failed(String)
    }

    @Published private(set) var state: State = .checking
    @Published private(set) var detail = "Checking Lumi Core…"

    private var process: Process?
    private var logHandle: FileHandle?
    private var isStopping = false

    private init() {}

    deinit {
        logHandle?.closeFile()
    }

    func ensureRunning() async {
        state = .checking
        detail = "Checking Lumi Core…"
        let client = LumiClientConfiguration.configuredClient()
        if await isReady(client) {
            state = process?.isRunning == true ? .runningManaged : .connected
            detail = process?.isRunning == true ? "Lumi Core is running with the app." : "Lumi Core is ready."
            return
        }

        guard Self.canAutoLaunch(client.baseURL) else {
            state = .remoteUnavailable(client.baseURL.absoluteString)
            detail = "Configured Lumi Core is unavailable or authentication failed. Only loopback HTTP Core can be auto-started by Lumi."
            return
        }

        if process?.isRunning == true {
            await waitUntilReady(client)
            return
        }
        guard let executable = Self.findCoreExecutable() else {
            state = .runtimeMissing
            detail = "Lumi Core runtime is not installed. Run scripts/install_lumi.sh."
            return
        }

        do {
            state = .starting
            detail = "Starting Lumi Core…"
            try launch(executable: executable, baseURL: client.baseURL)
            await waitUntilReady(client)
        } catch {
            state = .failed(error.localizedDescription)
            detail = "Failed to start Lumi Core: \(error.localizedDescription)"
        }
    }

    func restart() async {
        stopManagedCore()
        try? await Task.sleep(nanoseconds: 250_000_000)
        await ensureRunning()
    }

    func stopManagedCore() {
        isStopping = true
        defer { isStopping = false }
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            if process.isRunning { process.interrupt() }
        }
        process = nil
        logHandle?.closeFile()
        logHandle = nil
    }

    static func findCoreExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let explicit = environment["LUMI_CORE_EXECUTABLE"], !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: explicit))
        }

        let home = fm.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("Library/Application Support/Lumi/runtime/venv/bin/lumi-core"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/lumi-core"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/lumi-core"))

        let bundle = Bundle.main.bundleURL
        candidates.append(
            bundle
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(".venv/bin/lumi-core")
        )
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    static func canAutoLaunch(_ url: URL) -> Bool {
        isLoopback(url) && url.scheme?.lowercased() == "http"
    }

    private func launch(executable: URL, baseURL: URL) throws {
        guard Self.canAutoLaunch(baseURL) else {
            throw NSError(domain: "Lumi", code: 2, userInfo: [NSLocalizedDescriptionKey: "Managed Core requires a loopback HTTP URL"])
        }
        let port = baseURL.port ?? 80
        let fm = FileManager.default
        let applicationSupport = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Lumi")
        let dataDirectory = applicationSupport.appendingPathComponent("data")
        let logsDirectory = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lumi")
        try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        let logURL = logsDirectory.appendingPathComponent("core.log")
        if !fm.fileExists(atPath: logURL.path) {
            _ = fm.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()

        var environment = ProcessInfo.processInfo.environment
        if environment["LUMI_DATA_DIR"] == nil {
            environment["LUMI_DATA_DIR"] = dataDirectory.path
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--host", "127.0.0.1", "--port", String(port)]
        process.environment = environment
        process.currentDirectoryURL = applicationSupport
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        self.process = process
        self.logHandle = handle
    }

    private func waitUntilReady(_ client: LumiAPIClient) async {
        for _ in 0..<80 {
            if Task.isCancelled { return }
            if process != nil && process?.isRunning == false {
                let status = process?.terminationStatus ?? -1
                state = .failed("Core exited with status \(status)")
                detail = "Lumi Core stopped during startup. See ~/Library/Logs/Lumi/core.log."
                return
            }
            if await isReady(client) {
                state = process?.isRunning == true ? .runningManaged : .connected
                detail = process?.isRunning == true ? "Lumi Core started by the app." : "Lumi Core is ready."
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        state = .failed("Core did not become ready")
        detail = "Lumi Core did not become ready within 20 seconds. See ~/Library/Logs/Lumi/core.log."
    }

    private func isReady(_ client: LumiAPIClient) async -> Bool {
        do {
            let health = try await client.health()
            guard health.ok else { return false }
            let runtime = try await client.runtimeStatus()
            return runtime.ok
        } catch {
            return false
        }
    }
}
