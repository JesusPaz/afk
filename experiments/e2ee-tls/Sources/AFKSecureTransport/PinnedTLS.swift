import NIOSSL

/// Experimental configuration for peers whose certificates were verified out of band.
/// This does not perform enrollment or make the existing AFK apps end-to-end encrypted.
public enum PinnedTLS {
    public static let applicationProtocol = "afk-e2ee/2"

    public static func context(certificate: NIOSSLCertificate, privateKey: NIOSSLPrivateKey,
                               trustedPeer: NIOSSLCertificate) throws -> NIOSSLContext {
        var config = TLSConfiguration.makeClientConfiguration()
        config.minimumTLSVersion = .tlsv13
        config.maximumTLSVersion = .tlsv13
        config.certificateChain = [.certificate(certificate)]
        config.privateKey = .privateKey(privateKey)
        config.trustRoots = .certificates([trustedPeer])
        // Peers have device identities, not DNS names. Keep signature, chain and time validation.
        config.certificateVerification = .noHostnameVerification
        config.applicationProtocols = [applicationProtocol]
        return try NIOSSLContext(configuration: config)
    }

    public enum Failure: Error { case peerCertificateChanged }

    // NIOSSL's additional verification API is underscored: evaluate this API before promotion.
    public static func clientHandler(context: NIOSSLContext, trustedPeer: NIOSSLCertificate) throws -> NIOSSLClientHandler {
        let pin = try trustedPeer.toDERBytes()
        return try NIOSSLClientHandler._makeSSLClientHandler(context: context, serverHostname: nil) { certificate, channel in
            guard (try? certificate.toDERBytes()) == pin else {
                return channel.eventLoop.makeFailedFuture(Failure.peerCertificateChanged)
            }
            return channel.eventLoop.makeSucceededVoidFuture()
        }
    }

    public static func serverHandler(context: NIOSSLContext, trustedPeer: NIOSSLCertificate) throws -> NIOSSLServerHandler {
        let pin = try trustedPeer.toDERBytes()
        return NIOSSLServerHandler._makeSSLServerHandler(context: context) { certificate, channel in
            guard (try? certificate.toDERBytes()) == pin else {
                return channel.eventLoop.makeFailedFuture(Failure.peerCertificateChanged)
            }
            return channel.eventLoop.makeSucceededVoidFuture()
        }
    }

}
