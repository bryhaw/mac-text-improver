import Foundation
import Security

/// API keys live only in the user's login Keychain: never in UserDefaults, files, logs, or the repo.
enum Keychain {
    private static let service = "Copilot Proofreader API Keys"

    private static func query(_ provider: Provider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }

    static func apiKey(for provider: Provider) -> String? {
        var request = query(provider)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Checks for a saved key without reading it, so it never triggers a Keychain access prompt.
    static func hasAPIKey(for provider: Provider) -> Bool {
        var request = query(provider)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess
    }

    @discardableResult
    static func setAPIKey(_ key: String, for provider: Provider) -> OSStatus {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var item = query(provider)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Copilot Proofreader – \(provider.name) API key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil)
    }

    static func deleteAPIKey(for provider: Provider) {
        SecItemDelete(query(provider) as CFDictionary)
    }
}
