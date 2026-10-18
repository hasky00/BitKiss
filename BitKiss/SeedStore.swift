import Foundation
import Security
import LDKNode

/// Keeps the wallet's 12 recovery words in the iPhone Keychain.
///
/// Why Keychain and not a file? Files in the app folder vanish when the app
/// is deleted. The Keychain is encrypted by the phone's Secure Enclave and
/// only this app can read it. "ThisDeviceOnly" means it never leaves the
/// phone (no iCloud sync, no backup restore to another phone) -- the user's
/// written-down words are the real backup.
enum SeedStore {
    private static let service = "com.haskylabs.BitKiss"
    private static let account = "mnemonic"

    enum SeedError: Error { case keychain(OSStatus) }

    /// Returns the saved words, or makes a fresh 12-word phrase and saves it.
    static func loadOrCreate() throws -> Mnemonic {
        if let existing = try load() { return existing }
        let fresh = generateEntropyMnemonic(wordCount: .words12)
        try save(fresh)
        return fresh
    }

    static func load() throws -> Mnemonic? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SeedError.keychain(status) }
        guard let data = item as? Data,
              let words = String(data: data, encoding: .utf8) else { return nil }
        return words
    }

    private static func save(_ words: Mnemonic) throws {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(words.utf8),
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw SeedError.keychain(status) }
    }
}
