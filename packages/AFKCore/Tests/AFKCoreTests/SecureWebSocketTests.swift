import XCTest
import NIOCore
import NIOPosix
import NIOSSL
import CryptoKit
@testable import AFKCore

@MainActor final class SecureWebSocketTests: XCTestCase {
    func testFrameCoalescedWithHTTPUpgradeIsNotDiscarded() async throws {
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { $0.pipeline.addHandler(CoalescedUpgrade()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let transport = SecureTransport()
        let closed = expectation(description: "coalesced close frame reaches transport")
        closed.assertForOverFulfill = false
        transport.onClose = { closed.fulfill() }
        do {
            try await transport.connect(base: URL(string: "http://127.0.0.1:\(listener.localAddress!.port!)")!, path: "v2/accept/test", token: "test-only", identity: DeviceIdentity.create(), server: true, accepts: { _ in true })
        } catch { /* The peer closes immediately after upgrading. */ }
        await fulfillment(of: [closed], timeout: 2)
        transport.close(); try await listener.close().get()
    }
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

// One TCP write deliberately combines HTTP 101 and the first WebSocket frame.
private final class CoalescedUpgrade: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var request = ""
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        request += String(buffer: unwrapInboundIn(data))
        guard request.contains("\r\n\r\n") else { return }
        guard let line = request.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }) else { context.close(promise: nil); return }
        let key = line.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces)
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        var response = context.channel.allocator.buffer(capacity: 256)
        response.writeString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n")
        response.writeBytes([UInt8(0x88), 0x00])
        context.writeAndFlush(wrapOutboundOut(response), promise: nil)
        request = ""
    }
}
