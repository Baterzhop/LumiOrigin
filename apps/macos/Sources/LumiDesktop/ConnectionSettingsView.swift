import SwiftUI
import LumiClientCore

struct ConnectionSettingsView: View {
    @State private var baseURL = LumiClientConfiguration.baseURL().absoluteString
    @State private var apiKey = ""
    @State private var hasStoredKey = LumiClientConfiguration.hasStoredAPIKey()
    @State private var status = ""

    var body: some View {
        Form {
            Section("Lumi Core") {
                TextField("Base URL", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                Text("Default: http://127.0.0.1:8790")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("API key") {
                SecureField(hasStoredKey ? "Stored in Keychain" : "Optional for loopback-only use", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text(hasStoredKey ? "A key is stored in macOS Keychain." : "No Keychain API key is stored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if hasStoredKey {
                        Button("Remove key", role: .destructive) {
                            do {
                                try LumiClientConfiguration.clearAPIKey()
                                hasStoredKey = false
                                apiKey = ""
                                status = "API key removed. Restart Lumi to reconnect without it."
                            } catch {
                                status = error.localizedDescription
                            }
                        }
                    }
                }
            }

            HStack {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save") {
                    do {
                        try LumiClientConfiguration.setBaseURL(baseURL)
                        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            try LumiClientConfiguration.setAPIKey(apiKey)
                            hasStoredKey = true
                            apiKey = ""
                        }
                        status = "Saved. Restart Lumi so all windows use the new connection settings."
                    } catch {
                        status = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520, height: 300)
    }
}
