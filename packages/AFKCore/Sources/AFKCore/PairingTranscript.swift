import Foundation
import CryptoKit

// Each UTF-8 field is prefixed with its unsigned 32-bit big-endian byte length.
// Display the first 32 digest bits (big endian), modulo 100,000,000, zero padded.
public enum PairingTranscript {
    public static func digest(server: String, hostID: String, clientID: String, invitationID: String,
                              hostFingerprint: String, clientFingerprint: String,
                              clientNonce: String, hostNonce: String) -> Data {
        let fields = ["AFK enrollment comparison", "3", server, hostID, clientID, invitationID,
                      hostFingerprint, clientFingerprint, clientNonce, hostNonce]
        var data = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var count = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return Data(SHA256.hash(data: data))
    }
    public static func code(_ digest: Data) -> String {
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 100_000_000
        let digits = String(format: "%08u", value)
        return String(digits.prefix(4)) + " " + String(digits.suffix(4))
    }
}

public struct PairingCandidate: Identifiable {
    public let id: UUID
    public let clientID: String
    public let code: String
}
