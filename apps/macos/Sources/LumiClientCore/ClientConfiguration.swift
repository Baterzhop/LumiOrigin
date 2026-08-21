import Foundation
import Security

public enum LumiClientConfiguration {
    public enum ConfigurationError: LocalizedError {
        case invalidBaseURL
        case apiKeyTooShort
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "Lumi Core URL must be an absolute http or https origin without a path."
            case .apiKeyTooShort:
                return "Lumi API key must contain at least 24 characters."
            case .keychain(let status):
                return "Keychain operation failed (OSStatus \(status))."
            }
        }
    }

    private static let defaultsKey = "lumi.core.baseURL"
    private static let keychainService = "ai.lumi.desktop"
    private static let keychainAccount = "lumi-core-api-key"
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:8790")!

    public static func baseURL(defaults: UserDefaults = .standard) -> URL {
        guard let value = defaults.string(forKey: defaultsKey), let url = normalizedBaseURL(value) else {
            return defaultBaseURL
        }
        return url
    }

    public static func setBaseURL(_ value: String, defaults: UserDefaults = .standard) throws {
        guard let url = normalizedBaseURL(value) else { throw ConfigurationError.invalidBaseURL }
        defaults.set(url.absoluteString, forKey: defaultsKey)
    }

    public static func normalizedBaseURL(_ value: String) -> URL? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: clean),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        components.path = ""
        return components.url
    }

    public static func storedAPIKey() throws -> String? {
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
        guard status == errSecSuccess else { throw ConfigurationError.keychain(status) }
        guard let data = result as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    public static func hasStoredAPIKey() -> Bool {
        (try? storedAPIKey()) != nil
    }

    public static func setAPIKey(_ value: String) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 24 else { throw ConfigurationError.apiKeyTooShort }
        try clearAPIKey()
        let data = Data(clean.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ConfigurationError.keychain(status) }
    }

    public static func clearAPIKey() throws {
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
}
