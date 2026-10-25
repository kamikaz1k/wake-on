import Foundation
import Security

/// The OpenAI API key lives in the Keychain, never in the app bundle.
/// Debug builds can also read `OPENAI_API_KEY` from the launch environment,
/// which is how the simulator scripts pass it without writing it to disk.
enum OpenAIKeyStore {
    private static let service = "dev.wakeon.ios.openai"
    private static let account = "api-key"

    enum Source: String { case keychain, environment }

    /// Kept in memory after the first read: a Keychain lookup costs up to ~10 ms per call.
    nonisolated(unsafe) private static var cached: (key: String, source: Source)?

    static func load() -> (key: String, source: Source)? {
        if let cached { return cached }
        if let key = keychainKey() { cached = (key, .keychain); return cached }
        #if DEBUG
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            // Adopt it so later launches by iOS itself (the Action Button) still have a key.
            try? save(key)
            return (key, .environment)
        }
        #endif
        return nil
    }

    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoiceError.message("The API key is empty.") }
        delete()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Readable after the first unlock so an Action Button press works from the lock screen.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(trimmed.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw VoiceError.message("Keychain save failed (\(status)).") }
        cached = (trimmed, .keychain)
    }

    static func delete() {
        cached = nil
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    private static func keychainKey() -> String? {
        var result: AnyObject?
        let status = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword,
                                          kSecAttrService as String: service,
                                          kSecAttrAccount as String: account,
                                          kSecReturnData as String: true,
                                          kSecMatchLimit as String: kSecMatchLimitOne] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum VoiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
