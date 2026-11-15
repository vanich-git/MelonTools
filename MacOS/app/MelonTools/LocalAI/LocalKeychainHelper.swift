import Foundation
import Security

/// A Keychain call that did not succeed, with the OSStatus it returned.
///
/// The old reader mapped every status to `nil`, so a locked, denied or
/// otherwise broken Keychain was indistinguishable from "no token stored".
enum KeychainError: Error, Equatable {
    case status(OSStatus)
}

extension KeychainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .status(let status):
            return String(format: L("The macOS Keychain returned an error (status %d)."), status)
        }
    }
}

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
    ///
    /// Kept for callers that only need "a token or nothing". New code should use
    /// `loadHuggingFaceTokenResult()` so a Keychain failure is not mistaken for
    /// an absent token.
    static func loadHuggingFaceToken() -> String? {
        switch loadHuggingFaceTokenResult() {
        case .success(let token):
            return token
        case .failure:
            return nil
        }
    }

    /// Reads the token and keeps "not stored" apart from "could not ask".
    ///
    /// `errSecItemNotFound` is the only status that means the user has no token;
    /// every other status is reported as a failure carrying its code.
    static func loadHuggingFaceTokenResult() -> Result<String?, KeychainError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: hfAccountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                return .failure(.status(errSecDecode))
            }
            guard let token = String(data: data, encoding: .utf8) else {
                return .failure(.status(errSecDecode))
            }
            return .success(token)
        case errSecItemNotFound:
            return .success(nil)
        default:
            return .failure(.status(status))
        }
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
