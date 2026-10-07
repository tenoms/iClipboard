import Foundation
import Security

struct TranslationCredentialStore {
    private let service: String
    private let account = "doubao-session-id"

    init(
        service: String = Bundle.main.bundleIdentifier ?? "com.tenom.iClipboard"
    ) {
        self.service = service
    }

    func readSessionID() -> String? {
        readKeychainValue()
    }

    func saveSessionID(_ value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw CredentialStoreError.invalidData
        }

        let lookup = baseQuery
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            var item = lookup
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialStoreError.keychain(addStatus)
            }
        default:
            throw CredentialStoreError.keychain(updateStatus)
        }
    }

    func deleteSessionID() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func readKeychainValue() -> String? {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
private enum CredentialStoreError: LocalizedError {
    case invalidData
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "sessionid 无法编码"
        case let .keychain(status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return message ?? "钥匙串操作失败（\(status)）"
        }
    }
}
