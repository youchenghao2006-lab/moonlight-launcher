import Foundation
import Security

public actor CredentialVault {
    private let service: String
    public init(service: String = "dev.moonlight.launcher.microsoft") { self.service = service }
    private func query(_ id: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id] }
    private func failure(_ status: OSStatus) -> LauncherError {
        LauncherError("无法访问 macOS 钥匙串（\(status)）。请解锁登录钥匙串，并允许月光访问它。")
    }
    public func load(_ id: String) throws -> AccountCredential {
        var query = query(id)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw LauncherError("本机没有这个账号的登录凭证，请重新登录。") }
        guard status == errSecSuccess else { throw failure(status) }
        guard let data = item as? Data, let credential = try? JSONDecoder().decode(AccountCredential.self, from: data), credential.profileID == id else { throw LauncherError("保存的登录凭证无效，请重新登录。") }
        return credential
    }
    public func save(_ credential: AccountCredential) throws {
        _ = try credential.identity()
        let data = try JSONEncoder().encode(credential)
        let query = query(credential.profileID)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query
            entry[kSecValueData as String] = data
            entry[kSecAttrLabel as String] = "Moonlight · \(credential.profileName)"
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            entry[kSecAttrSynchronizable as String] = false
            let added = SecItemAdd(entry as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    public func remove(_ id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
}
