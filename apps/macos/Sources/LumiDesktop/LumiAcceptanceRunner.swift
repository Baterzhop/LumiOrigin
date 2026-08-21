import Foundation
import LumiClientCore

struct LumiAcceptanceRun: Sendable {
    let report: LumiAcceptanceReport
    let rawOutput: String
}

enum LumiAcceptanceRunner {
    enum RunnerError: LocalizedError {
        case runtimeMissing
        case failed(Int32, String)
        case invalidOutput(String)

        var errorDescription: String? {
            switch self {
            case .runtimeMissing:
                return "The installed Lumi Core runtime was not found. Re-run scripts/install_lumi.sh."
            case .failed(let status, let output):
                return "Acceptance failed with status \(status).\n\(output)"
            case .invalidOutput(let output):
                return "Acceptance returned invalid JSON.\n\(output)"
            }
        }
    }

    static func run(requireModel: Bool) async throws -> LumiAcceptanceRun {
        guard let executable = CoreProcessManager.findCoreExecutable() else {
            throw RunnerError.runtimeMissing
        }
        let baseURL = LumiClientConfiguration.defaultBaseURL()
        let apiKey = LumiClientConfiguration.defaultAPIKey()
        let arguments = LumiAcceptanceConfiguration.arguments(baseURL: baseURL, requireModel: requireModel)
        let environment = LumiAcceptanceConfiguration.environment(apiKey: apiKey)

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            let combined = [stdoutText, stderrText]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")

            guard process.terminationStatus == 0 else {
                throw RunnerError.failed(process.terminationStatus, combined)
            }
            do {
                let report = try LumiAcceptanceConfiguration.decodeReport(stdoutData)
                return LumiAcceptanceRun(report: report, rawOutput: stdoutText)
            } catch {
                throw RunnerError.invalidOutput(combined)
            }
        }.value
    }
}
