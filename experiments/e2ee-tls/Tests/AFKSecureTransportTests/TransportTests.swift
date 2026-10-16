import Foundation
import XCTest
import NIOCore
import NIOEmbedded
import NIOSSL
import NIOTLS
@testable import AFKSecureTransport

final class TransportTests: XCTestCase {
    struct Identity {
        let certificate: NIOSSLCertificate
        let key: NIOSSLPrivateKey

        static func generate(in directory: URL, name: String) throws -> Identity {
            let key = directory.appendingPathComponent("\(name).key").path
            let cert = directory.appendingPathComponent("\(name).pem").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                                 "-pkeyopt", "ec_param_enc:named_curve", "-sha256",
                                 "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=\(name)",
                                 "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                                 "-addext", "keyUsage=critical,digitalSignature,keyCertSign",
                                 "-addext", "extendedKeyUsage=serverAuth,clientAuth"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.fixtureGeneration }
            return try Identity(certificate: NIOSSLCertificate.fromPEMFile(cert)[0],
                                key: NIOSSLPrivateKey(file: key, format: .pem))
        }

        func context(trusting peer: Identity) throws -> NIOSSLContext {
            try PinnedTLS.context(certificate: certificate, privateKey: key, trustedPeer: peer.certificate)
        }
    }

    enum Failure: Error { case fixtureGeneration, handshakeDidNotComplete, unexpectedRecord, pumpLimit }
    var directory: URL!
    var mac: Identity!
    var phone: Identity!
    var attacker: Identity!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        mac = try Identity.generate(in: directory, name: "mac")
        phone = try Identity.generate(in: directory, name: "phone")
        attacker = try Identity.generate(in: directory, name: "attacker")
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    final class Handshake: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        var complete = false
        var negotiated: String?
        var errors: [Error] = []
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            errors.append(error)
            context.fireErrorCaught(error)
        }
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case let TLSUserEvent.handshakeCompleted(negotiatedProtocol) = event {
                complete = true; negotiated = negotiatedProtocol
            }
            context.fireUserInboundEventTriggered(event)
        }
    }

    final class Pair {
        let client = EmbeddedChannel()
        let server = EmbeddedChannel()
        let clientHandshake = Handshake()
        let serverHandshake = Handshake()
        var captured = Data()

        init(clientContext: NIOSSLContext, serverContext: NIOSSLContext) throws {
            guard case let .certificates(serverPins) = clientContext.configuration.trustRoots,
                  case let .certificates(clientPins) = serverContext.configuration.trustRoots else {
                throw Failure.fixtureGeneration
            }
            try client.pipeline.syncOperations.addHandler(PinnedTLS.clientHandler(context: clientContext, trustedPeer: serverPins[0]))
            try client.pipeline.syncOperations.addHandler(PeerProtocolGate())
            try client.pipeline.syncOperations.addHandler(clientHandshake)
            try server.pipeline.syncOperations.addHandler(PinnedTLS.serverHandler(context: serverContext, trustedPeer: clientPins[0]))
            try server.pipeline.syncOperations.addHandler(PeerProtocolGate())
            try server.pipeline.syncOperations.addHandler(serverHandshake)
        }

        deinit {
            client.close(promise: nil); server.close(promise: nil)
            try? pump()
            client.embeddedEventLoop.advanceTime(by: .seconds(10))
            server.embeddedEventLoop.advanceTime(by: .seconds(10))
            _ = try? client.finish(acceptAlreadyClosed: true)
            _ = try? server.finish(acceptAlreadyClosed: true)
        }

        func start() throws {
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: 443)
            try server.connect(to: address).wait()
            try client.connect(to: address).wait()
            try pump()
            guard clientHandshake.complete, serverHandshake.complete else { throw Failure.handshakeDidNotComplete }
        }

        func take(_ channel: EmbeddedChannel) throws -> ByteBuffer? {
            guard let data = try channel.readOutbound(as: IOData.self) else { return nil }
            guard case let .byteBuffer(buffer) = data else { throw Failure.unexpectedRecord }
            captured.append(contentsOf: buffer.readableBytesView)
            return buffer
        }

        func pump(fragmentSize: Int = Int.max) throws {
            for _ in 0..<100 {
                client.embeddedEventLoop.run(); server.embeddedEventLoop.run()
                var progressed = false
                for (source, destination) in [(client, server), (server, client)] {
                    if var bytes = try take(source) {
                        progressed = true
                        while bytes.readableBytes > 0 {
                            let count = min(fragmentSize, bytes.readableBytes)
                            try destination.writeInbound(bytes.readSlice(length: count)!)
                        }
                    }
                }
                if !progressed { return }
            }
            throw Failure.pumpLimit
        }

        func send(_ text: String, from channel: EmbeddedChannel) throws {
            var buffer = channel.allocator.buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            try channel.writeOutbound(buffer)
        }

        func receive(from channel: EmbeddedChannel) throws -> String {
            var result = ""
            while var buffer = try channel.readInbound(as: ByteBuffer.self) {
                result += buffer.readString(length: buffer.readableBytes)!
            }
            return result
        }
    }

    func paired() throws -> Pair {
        let pair = try Pair(clientContext: phone.context(trusting: mac), serverContext: mac.context(trusting: phone))
        try pair.start()
        return pair
    }

    func testMutualTLS13EncryptsBothDirectionsAcrossFragmentedRelay() throws {
        let pair = try paired()
        XCTAssertEqual(try pair.client.pipeline.syncOperations.nioSSL_tlsVersion(), .tlsv13)
        XCTAssertEqual(try pair.server.pipeline.syncOperations.nioSSL_tlsVersion(), .tlsv13)
        XCTAssertEqual(pair.clientHandshake.negotiated, PinnedTLS.applicationProtocol)
        XCTAssertEqual(pair.serverHandshake.negotiated, PinnedTLS.applicationProtocol)
        let command = "printf 'afk-private-command-489cbd'\n"
        let output = "afk-private-terminal-output-8ae5cd"
        try pair.send(command, from: pair.client)
        try pair.send(output, from: pair.server)
        try pair.pump(fragmentSize: 7)
        XCTAssertEqual(try pair.receive(from: pair.server), command)
        XCTAssertEqual(try pair.receive(from: pair.client), output)
        XCTAssertNil(pair.captured.range(of: Data(command.utf8)))
        XCTAssertNil(pair.captured.range(of: Data(output.utf8)))
    }

    func testRelayCannotSubstituteMacCertificate() throws {
        let pair = try Pair(clientContext: phone.context(trusting: mac), serverContext: attacker.context(trusting: phone))
        XCTAssertThrowsError(try pair.start())
        XCTAssertFalse(pair.clientHandshake.complete)
        XCTAssertEqual(try pair.receive(from: pair.client), "")
    }

    func testRelayCannotSubstitutePhoneCertificate() throws {
        let pair = try Pair(clientContext: attacker.context(trusting: mac), serverContext: mac.context(trusting: phone))
        XCTAssertThrowsError(try pair.start())
        XCTAssertFalse(pair.serverHandshake.complete)
        XCTAssertEqual(try pair.receive(from: pair.server), "")
    }

    func testCertificateSignedByTrustedDeviceStillNeedsExactPin() throws {
        let csr = directory.appendingPathComponent("delegated.csr").path
        let cert = directory.appendingPathComponent("delegated.pem").path
        let key = directory.appendingPathComponent("attacker.key").path
        let commands = [
            ["x509", "-x509toreq", "-in", directory.appendingPathComponent("attacker.pem").path,
             "-signkey", key, "-out", csr],
            ["x509", "-req", "-in", csr, "-CA", directory.appendingPathComponent("mac.pem").path,
             "-CAkey", directory.appendingPathComponent("mac.key").path,
             "-set_serial", "123", "-days", "1", "-sha256", "-out", cert],
        ]
        for arguments in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.fixtureGeneration }
        }
        let delegated = try Identity(certificate: NIOSSLCertificate.fromPEMFile(cert)[0], key: attacker.key)
        let pair = try Pair(clientContext: phone.context(trusting: mac), serverContext: delegated.context(trusting: phone))
        XCTAssertThrowsError(try pair.start())
        XCTAssertTrue(pair.clientHandshake.errors.contains { $0 is PinnedTLS.Failure })
        XCTAssertEqual(try pair.receive(from: pair.client), "")
    }

    func testMissingClientCertificateFailsClosed() throws {
        var config = TLSConfiguration.makeClientConfiguration()
        config.minimumTLSVersion = .tlsv13
        config.trustRoots = .certificates([mac.certificate])
        config.certificateVerification = .noHostnameVerification
        config.applicationProtocols = [PinnedTLS.applicationProtocol]
        let pair = try Pair(clientContext: NIOSSLContext(configuration: config), serverContext: mac.context(trusting: phone))
        XCTAssertThrowsError(try pair.start())
        XCTAssertFalse(pair.serverHandshake.complete)
    }

    func testTLS12DowngradeFailsClosed() throws {
        var config = TLSConfiguration.makeClientConfiguration()
        config.maximumTLSVersion = .tlsv12
        config.certificateChain = [.certificate(phone.certificate)]
        config.privateKey = .privateKey(phone.key)
        config.trustRoots = .certificates([mac.certificate])
        config.certificateVerification = .noHostnameVerification
        let pair = try Pair(clientContext: NIOSSLContext(configuration: config), serverContext: mac.context(trusting: phone))
        XCTAssertThrowsError(try pair.start())
        XCTAssertFalse(pair.serverHandshake.complete)
    }

    func testMissingAFKProtocolFailsClosed() throws {
        var config = TLSConfiguration.makeClientConfiguration()
        config.minimumTLSVersion = .tlsv13
        config.certificateChain = [.certificate(phone.certificate)]
        config.privateKey = .privateKey(phone.key)
        config.trustRoots = .certificates([mac.certificate])
        config.certificateVerification = .noHostnameVerification
        let pair = try Pair(clientContext: NIOSSLContext(configuration: config), serverContext: mac.context(trusting: phone))
        XCTAssertThrowsError(try pair.start())
        XCTAssertEqual(try pair.receive(from: pair.server), "")
    }

    func testCommandsCannotBeQueuedBeforeAuthentication() throws {
        let pair = try Pair(clientContext: phone.context(trusting: mac), serverContext: mac.context(trusting: phone))
        XCTAssertThrowsError(try pair.send("do not buffer this command", from: pair.client))
        XCTAssertNil(try pair.take(pair.client))
        XCTAssertEqual(try pair.receive(from: pair.server), "")
    }

    func testModifiedCiphertextIsRejectedWithoutDeliveringPlaintext() throws {
        let pair = try paired()
        try pair.send("private input", from: pair.client)
        var record = try XCTUnwrap(pair.take(pair.client))
        let last = record.writerIndex - 1
        record.setInteger(record.getInteger(at: last, as: UInt8.self)! ^ 1, at: last)
        XCTAssertThrowsError(try pair.server.writeInbound(record))
        XCTAssertEqual(try pair.receive(from: pair.server), "")
    }

    func testSameConnectionReplayIsRejected() throws {
        let pair = try paired()
        try pair.send("run once", from: pair.client)
        let record = try XCTUnwrap(pair.take(pair.client))
        try pair.server.writeInbound(record)
        XCTAssertEqual(try pair.receive(from: pair.server), "run once")
        XCTAssertThrowsError(try pair.server.writeInbound(record))
        XCTAssertEqual(try pair.receive(from: pair.server), "")
    }

    func testOldConnectionRecordIsRejectedAfterReconnect() throws {
        let old = try paired()
        try old.send("old input", from: old.client)
        let record = try XCTUnwrap(old.take(old.client))
        let fresh = try paired()
        XCTAssertThrowsError(try fresh.server.writeInbound(record))
        XCTAssertEqual(try fresh.receive(from: fresh.server), "")
    }

    func testReorderedRecordsAreRejected() throws {
        let pair = try paired()
        try pair.send("first", from: pair.client)
        _ = try XCTUnwrap(pair.take(pair.client))
        try pair.send("second", from: pair.client)
        let second = try XCTUnwrap(pair.take(pair.client))
        XCTAssertThrowsError(try pair.server.writeInbound(second))
        XCTAssertEqual(try pair.receive(from: pair.server), "")
    }

    func testIncompleteRecordDeliversNoPlaintext() throws {
        let pair = try paired()
        try pair.send("incomplete input", from: pair.client)
        var record = try XCTUnwrap(pair.take(pair.client))
        try pair.server.writeInbound(record.readSlice(length: record.readableBytes - 1)!)
        XCTAssertEqual(try pair.receive(from: pair.server), "")
    }
}
