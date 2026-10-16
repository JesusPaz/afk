import XCTest
import NIOCore
import NIOPosix
import NIOSSL
@testable import AFKCore

@MainActor final class SecureWebSocketTests: XCTestCase {
    func testWSSRejectsUntrustedRelayCertificateBeforeDeviceHandshake() async throws {
        let relayIdentity = try DeviceIdentity.create()
        var config = try relayIdentity.tlsConfiguration(server: true)
        config.certificateVerification = .none
        config.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: config)
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in channel.pipeline.addHandler(NIOSSLServerHandler(context: context)) }
            .bind(host: "127.0.0.1", port: 0).get()
        let transport = SecureTransport()
        var deviceHandshake = false
        transport.onReady = { _ in deviceHandshake = true }
        do {
            try await transport.connect(base: URL(string: "https://localhost:\(listener.localAddress!.port!)")!, path: "v2/connect", token: "test-only", identity: DeviceIdentity.create(), server: false, accepts: { _ in true })
            XCTFail("Untrusted relay certificate accepted")
        } catch { XCTAssertFalse(deviceHandshake) }
        transport.close(); try await listener.close().get()
    }
}
