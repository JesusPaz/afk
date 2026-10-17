import Foundation
import CryptoKit
import LocalAuthentication
import NIOCore
import NIOSSL

// BoringSSL asks for a TLS transcript signature; private key bytes never leave the enclave.
final class EnclaveTLSKey: NIOSSLCustomPrivateKey, Hashable, @unchecked Sendable {
    private let id = UUID()
    private let blob: Data
    private let context: LAContext
    var signatureAlgorithms: [SignatureAlgorithm] { [.ecdsaSecp256R1Sha256] }
    init(blob: Data, context: LAContext) {
        self.blob = blob; self.context = context
        context.localizedReason = L10n.text("Confirma tu identidad para autorizar el acceso a la terminal del Mac.")
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
    }
    static func == (lhs: EnclaveTLSKey, rhs: EnclaveTLSKey) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    func sign(channel: Channel, algorithm: SignatureAlgorithm, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        guard algorithm == .ecdsaSecp256R1Sha256 else { return channel.eventLoop.makeFailedFuture(SecureError.protocolViolation) }
        let promise = channel.eventLoop.makePromise(of: ByteBuffer.self)
        let message = Data(data.readableBytesView)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
                let signature = try key.signature(for: message).derRepresentation
                promise.succeed(ByteBuffer(bytes: signature))
            } catch { promise.fail(error) }
        }
        return promise.futureResult
    }
    func decrypt(channel: Channel, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        channel.eventLoop.makeFailedFuture(SecureError.protocolViolation)
    }
}
