import Foundation
import Security
import LocalAuthentication

enum KeychainHelper {
    struct LookupResult {
        let status: OSStatus
        let data: Data?
    }

    static func getData(service: String, account: String, allowUserInteraction: Bool = false) -> LookupResult {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        let context = LAContext()
        context.interactionNotAllowed = !allowUserInteraction
        if allowUserInteraction {
            context.touchIDAuthenticationAllowableReuseDuration = LATouchIDAuthenticationMaximumAllowableReuseDuration
        }
        query[kSecUseAuthenticationContext] = context

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return LookupResult(status: status, data: result as? Data)
    }

    static func get(service: String, account: String, allowUserInteraction: Bool = false) -> String? {
        let lookup = getData(
            service: service,
            account: account,
            allowUserInteraction: allowUserInteraction
        )
        guard lookup.status == errSecSuccess, let data = lookup.data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, service: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
