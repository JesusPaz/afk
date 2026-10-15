import Foundation
import Security

public enum SecretStore {
    public static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AFKError.message("No se pudo crear una identidad segura.") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func read<T: Decodable>(_ account: String) throws -> T? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.jesuspaz.afk.poc", kSecAttrAccount as String: account, kSecReturnData as String: true]
        var value: CFTypeRef?; let result = SecItemCopyMatching(query as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = value as? Data else { throw AFKError.message("No se pudo leer el llavero (\(result)).") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    public static func write<T: Encodable>(_ value: T, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.jesuspaz.afk.poc", kSecAttrAccount as String: account]
        let data = try JSONEncoder().encode(value)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = data; insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw AFKError.message("No se pudo guardar el vínculo en el llavero.") }
        } else if result != errSecSuccess { throw AFKError.message("No se pudo actualizar el llavero.") }
    }
}
