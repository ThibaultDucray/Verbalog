import Foundation
import Security

/// Same service and account names as the `keyring` calls in verbalog/keychain.py.
public enum Keychain {
    public static let service = "verbalog"

    public enum Item: String, CaseIterable, Sendable {
        case anthropicKey = "anthropic-api-key"
        case hfToken = "hf-token"
        case voiceprintKey = "voiceprint-key"

        /// The variable through which the backend receives it.
        public var environmentName: String {
            switch self {
            case .anthropicKey: "ANTHROPIC_API_KEY"
            case .hfToken: "HF_TOKEN"
            case .voiceprintKey: "VERBALOG_VOICEPRINT_KEY"
            }
        }
    }

    private static func query(_ item: Item) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
    }

    public static func get(_ item: Item) -> String? {
        var request = query(item)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func has(_ item: Item) -> Bool {
        // Attributes only: no secret is read, so no Keychain prompt.
        var request = query(item)
        request[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    public static func set(_ item: Item, value: String) throws {
        SecItemDelete(query(item) as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query(item)
        attributes[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BackendError(message: SecCopyErrorMessageString(status, nil) as String? ?? L("Keychain error (\(status))"))
        }
    }

    /// Voiceprints are encrypted with this key: created on first need, as a Fernet key (urlsafe base64 of 32 bytes).
    public static func ensureVoiceprintKey() throws -> String {
        if let existing = get(.voiceprintKey) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BackendError(message: L("Can't generate key"))
        }
        let key = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        try set(.voiceprintKey, value: key)
        return key
    }
}
