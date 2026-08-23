import Foundation
import Security

struct YuhaiinAPICredentials {
    let username: String
    let password: String
}

enum YuhaiinKeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidStoredValue

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            return L("error.keychainStatus", String(status))
        case .invalidStoredValue:
            return L("error.keychainInvalidCredentials")
        }
    }
}

final class YuhaiinKeychain {
    private let service = "com.asutorufa.yuhaiin.macos.api"
    private let usernameAccount = "username"
    private let passwordAccount = "password"

    func read() throws -> YuhaiinAPICredentials? {
        guard let username = try read(account: usernameAccount),
              let password = try read(account: passwordAccount) else {
            return nil
        }
        guard let username = String(data: username, encoding: .utf8),
              let password = String(data: password, encoding: .utf8) else {
            throw YuhaiinKeychainError.invalidStoredValue
        }
        return YuhaiinAPICredentials(username: username, password: password)
    }

    func save(_ credentials: YuhaiinAPICredentials) throws {
        try save(Data(credentials.username.utf8), account: usernameAccount)
        try save(Data(credentials.password.utf8), account: passwordAccount)
    }

    func delete() throws {
        try delete(account: usernameAccount)
        try delete(account: passwordAccount)
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func read(account: String) throws -> Data? {
        var item: CFTypeRef?
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw YuhaiinKeychainError.unexpectedStatus(status)
        }
        return item as? Data
    }

    private func save(_ data: Data, account: String) throws {
        let lookup = query(account: account) as CFDictionary
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(lookup, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw YuhaiinKeychainError.unexpectedStatus(updateStatus)
        }

        var item = query(account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw YuhaiinKeychainError.unexpectedStatus(addStatus)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw YuhaiinKeychainError.unexpectedStatus(status)
        }
    }
}
