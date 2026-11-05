import Foundation
import Security

/// Secure storage helper for sensitive tokens (such as Hugging Face Access Token) in macOS Keychain.
enum LocalKeychainHelper {
    private static let serviceName = "dev.melontools.mac.local-ai"
    private static let hfAccountKey = "huggingface_access_token"

    /// Saves the token without deleting the previous one first.
    ///
    /// The old implementation removed the existing item and then ignored the
    /// result of `SecItemAdd`, so a locked or denied Keychain destroyed the
    /// working token and the UI still said "Saved".
    @discardableResult
    static func saveHuggingFaceToken(_ token: String) -> OSStatus {
        guard let data = token.data(using: .utf8) else { return errSecParam }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: hfAccountKey,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return errSecSuccess }
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var insert = query
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil)
    }

    /// Read token from Keychain.
    static func loadHuggingFaceToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: hfAccountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the token. A missing item is a success: the caller asked for
    /// "no token", and that is the state that results.
    @discardableResult
    static func deleteHuggingFaceToken() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: hfAccountKey
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}
