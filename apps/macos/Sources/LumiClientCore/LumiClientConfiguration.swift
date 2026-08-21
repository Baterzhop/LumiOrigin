import Foundation
import Security

public enum LumiClientConfiguration {
    public enum ConfigurationError: LocalizedError {
        case invalidURL
        case insecureRemoteHTTP
        case embeddedCredentials
        case unsupportedURLComponents
        case apiKeyTooShort
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Enter a valid HTTP or HTTPS Lumi Core URL."
            case .insecureRemoteHTTP:
                return "Plain HTTP is allowed only for localhost. Use HTTPS for remote Lumi Core connections."
            case .embeddedCredentials:
                return "Do not place usernames, passwords or API keys in the Core URL. Store the Lumi API key in Keychain instead."
            case .unsupportedURLComponents:
                return "The Lumi Core base URL cannot contain a query string or fragment."
            case .apiKeyTooShort:
                return "Lumi API keys must contain at least 24 characters."
            case .keychain(let status):
                return "Keychain operation failed (OSStatus \(status))."
            }
        }
    }

    private static let defaultsURLKey = "Lumi.Core.BaseURL"
    private static let keychainService = "app.lumi.desktop"
    private static let keychainAccount = "core-api-key"

    public static func defaultBaseURL() -> URL {
        if let environment = ProcessInfo.processInfo.environment["LUMI_CORE_URL"],
           let url = try? validatedBaseURL(environment) {
            return url
        }
        if let stored = UserDefaults.standard.string(forKey: defaultsURLKey),
           let url = try? validatedBaseURL(stored) {
            return url
        }
        return URL(string: "http://127.0.0.1:8790")!
    }

    public static func defaultAPIKey() -> String? {
        if let environment = ProcessInfo.processInfo.environment["LUMI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environment.isEmpty {
            return environment
        }
        return try? readKeychainAPIKey()
    }

    public static func configuredClient() -> LumiAPIClient {
        LumiAPIClient(baseURL: defaultBaseURL(), apiKey: defaultAPIKey())
    }

    public static func validatedBaseURL(_ value: String) throws -> URL {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: clean),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            throw ConfigurationError.invalidURL
        }
        if components.user != nil || components.password != nil {
            throw ConfigurationError.embeddedCredentials
        }
        if components.query != nil || components.fragment != nil {
            throw ConfigurationError.unsupportedURLComponents
        }
        if scheme == "http" && !isLoopbackHost(host) {
            throw ConfigurationError.insecureRemoteHTTP
        }
        return url
    }

    public static func saveBaseURL(_ value: String) throws {
        let url = try validatedBaseURL(value)
        UserDefaults.standard.set(url.absoluteString, forKey: defaultsURLKey)
    }

    public static func resetBaseURL() {
        UserDefaults.standard.removeObject(forKey: defaultsURLKey)
    }

    public static func hasStoredAPIKey() -> Bool {
        (try? readKeychainAPIKey()) != nil
    }

    public static func saveAPIKey(_ value: String) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            try deleteAPIKey()
            return
        }
        guard clean.count >= 24 else { throw ConfigurationError.apiKeyTooShort }
        let data = Data(clean.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ConfigurationError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw ConfigurationError.keychain(status)
        }
    }

    public static func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConfigurationError.keychain(status)
        }
    }

    private static func readKeychainAPIKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ConfigurationError.keychain(status)
        }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let value = host.lowercased()
        return value == "localhost" || value == "127.0.0.1" || value == "::1" || value == "[::1]"
    }
}
