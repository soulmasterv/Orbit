import Foundation
import Security

enum KeychainManager {
    static func loadMobileState() throws -> MobileSecureState {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ServerControl", kSecAttrAccount as String: "mobile-state.v1",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return MobileSecureState() }
        guard status == errSecSuccess, let data = result as? Data else { throw APIError.message("Unlock iPhone to read the saved mobile state.") }
        return try JSONDecoder().decode(MobileSecureState.self, from: data)
    }

    static func saveMobileState(_ state: MobileSecureState) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ServerControl", kSecAttrAccount as String: "mobile-state.v1"]
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(state),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw APIError.message("Could not securely save mobile state. No new send will be dispatched.") }
    }
    // Preserve V1's identity so an in-place SideStore update can keep the token.
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ServerControl",
         kSecAttrAccount as String: "server-token"]
    }
    static func save(token: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw APIError.message("The token could not be saved securely. Unlock your iPhone and try again.")
        }
    }
    static func load() -> String {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIError.message("The token could not be removed. Unlock your iPhone and try again.")
        }
    }

    // One Keychain record keeps the Students URL and key together atomically.
    private static var studentsQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ServerControl",
         kSecAttrAccount as String: "students-connection.v1"]
    }
    static func loadStudentsConnection() throws -> StudentsConnection? {
        var lookup = studentsQuery
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw APIError.message("Unlock your iPhone to read the Students connection from Keychain.")
        }
        return try JSONDecoder().decode(StudentsConnection.self, from: data)
    }
    @MainActor static func saveStudentsConnection(_ connection: StudentsConnection) throws {
        let valid = try connection.validated()
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(valid),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(studentsQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(studentsQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw APIError.message("The Students connection could not be saved securely. Unlock your iPhone and try again.")
        }
    }
}


