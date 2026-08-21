import SwiftUI
import LumiClientCore

struct LumiSettingsView: View {
    @State private var coreURL = LumiClientConfiguration.defaultBaseURL().absoluteString
    @State private var apiKey = ""
    @State private var status = LumiClientConfiguration.hasStoredAPIKey()
        ? "An API key is stored in Keychain."
        : "No API key is stored. Local loopback mode does not require one."
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Lumi Core") {
                TextField("Core URL", text: $coreURL)
                    .textFieldStyle(.roundedBorder)
                Text("HTTP is accepted only for localhost. Remote Core connections must use HTTPS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Authentication") {
                SecureField("New API key (leave blank to keep current)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Remote/LAN access requires a Core API key of at least 24 characters. Keys are stored in macOS Keychain, not UserDefaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Remove stored API key", role: .destructive) {
                        do {
                            try LumiClientConfiguration.deleteAPIKey()
                            apiKey = ""
                            status = "Stored API key removed."
                        } catch {
                            status = error.localizedDescription
                        }
                    }
                    .disabled(!LumiClientConfiguration.hasStoredAPIKey())
                    Spacer()
                }
            }

            Section("Connection") {
                Text(status)
                    .font(.caption)
                    .textSelection(.enabled)
                HStack {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                    Button("Test connection") { testConnection() }
                        .disabled(isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                }
                Text("Connection changes apply to newly created views. Restart Lumi after changing the Core URL or authentication settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(18)
        .frame(width: 560, height: 390)
    }

    private func save() {
        do {
            try LumiClientConfiguration.saveBaseURL(coreURL)
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try LumiClientConfiguration.saveAPIKey(apiKey)
                apiKey = ""
            }
            status = LumiClientConfiguration.hasStoredAPIKey()
                ? "Saved. API key is stored in Keychain."
                : "Saved. Local loopback mode has no API key."
        } catch {
            status = error.localizedDescription
        }
    }

    private func testConnection() {
        isTesting = true
        status = "Testing connection and authentication…"
        Task {
            defer { isTesting = false }
            do {
                let url = try LumiClientConfiguration.validatedBaseURL(coreURL)
                let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                let client = LumiAPIClient(
                    baseURL: url,
                    apiKey: key.isEmpty ? LumiClientConfiguration.defaultAPIKey() : key
                )
                let health = try await client.health()
                let runtime = try await client.runtimeStatus()
                status = health.ok && runtime.ok
                    ? "Connection and authentication successful: Lumi Core \(health.version)."
                    : "Core responded but did not report ready runtime state."
            } catch {
                status = "Connection/authentication failed: \(error.localizedDescription)"
            }
        }
    }
}
