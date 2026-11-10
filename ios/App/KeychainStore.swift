import DogMonitorCore
import Foundation
import Security

/// `SecureStore` backed by the iOS Keychain (generic passwords, this device only).
struct KeychainStore: SecureStore {
    var service = "com.benooon.dogmonitor"

    enum KeychainError: Error {
        case status(OSStatus)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func data(forKey key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.status(status)
        }
    }

    func setData(_ data: Data?, forKey key: String) throws {
        let base = baseQuery(key)
        guard let data else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
            return
        }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            // Camera phones stay locked-free on a charger; still keep secrets off backups/other devices.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }
}
