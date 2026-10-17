import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import NIOTLS
import LocalAuthentication

struct SecurePacket: Codable {
    var type: String
    var version: Int = 2
    var server: String?
    var hostID: String?
    var clientID: String?
    var nonce: String?
    var invitationID: String?
    var ceremony: Int?
    var approvalID: String?
    var hostNonce: String?
    var secret: String?
    var name: String?
    var fingerprint: String?
    var biometricIdentity: Bool?
    var message: Message?
}

// A WebSocket carries an opaque TLS byte stream. TLS, not WebSocket message boundaries,
// authenticates ordering, integrity and the remote device.
private final class WebSocketBytes: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = IOData
    typealias OutboundOut = WebSocketFrame
    private var started = false
    private var context: ChannelHandlerContext?
    private var pending: [(NIOAny, EventLoopPromise<Void>?)] = []
    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func activate() {
        guard let context else { return }; started = true
        let queued = pending; pending.removeAll()
        for (data, promise) in queued { write(context: context, data: data, promise: promise) }
        context.flush()
    }
    func handlerRemoved(context: ChannelHandlerContext) {
        for (_, promise) in pending { promise?.fail(SecureError.disconnected) }; pending.removeAll(); self.context = nil
    }
    private var fragmenting = false
    private var fragmentBytes = 0
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData)), promise: nil)
        case .pong: break
        case .binary, .continuation:
            guard (frame.opcode == .continuation) == fragmenting else { context.close(promise: nil); return }
            fragmentBytes += frame.unmaskedData.readableBytes
            guard fragmentBytes <= 65536 else { context.close(promise: nil); return }
            fragmenting = !frame.fin
            if frame.fin { fragmentBytes = 0 }
            context.fireChannelRead(wrapInboundOut(frame.unmaskedData))
        default: context.close(promise: nil)
        }
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if !started {
            guard pending.count < 16 else { promise?.fail(SecureError.protocolViolation); context.close(promise: nil); return }
            pending.append((data, promise)); return
        }
        guard case .byteBuffer(var bytes) = unwrapOutboundIn(data) else { promise?.fail(SecureError.protocolViolation); context.close(promise: nil); return }
        while bytes.readableBytes > 65536 {
            context.write(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: bytes.readSlice(length: 65536)!)), promise: nil)
        }
        context.write(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: bytes)), promise: promise)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private final class SecureRecords: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var buffer = ByteBuffer()
    private var ready = false
    var peer: Data?
    let onReady: (Data) -> Void
    private var queuedCount = 0
    private var queuedBytes = 0
    let onPacket: (SecurePacket, @escaping () -> Void) -> Void
    let onClose: () -> Void
    private var timeout: Scheduled<Void>?
    init(onReady: @escaping (Data) -> Void, onPacket: @escaping (SecurePacket, @escaping () -> Void) -> Void, onClose: @escaping () -> Void) {
        self.onReady = onReady; self.onPacket = onPacket; self.onClose = onClose
    }
    func handlerAdded(context: ChannelHandlerContext) {
        timeout = context.eventLoop.scheduleTask(in: .seconds(60)) { context.close(promise: nil) }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .handshakeCompleted(let protocolName) = event as? TLSUserEvent {
            guard protocolName == "afk-e2ee/2", let peer else { context.close(promise: nil); return }
            ready = true; timeout?.cancel(); onReady(peer);
        }
        context.fireUserInboundEventTriggered(event)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard ready else { context.close(promise: nil); return }
        var input = unwrapInboundIn(data)
        buffer.writeBuffer(&input)
        while let size: UInt32 = buffer.getInteger(at: buffer.readerIndex) {
            guard size > 0, size <= 512 * 1024 else { context.close(promise: nil); return }
            guard buffer.readableBytes >= 4 + Int(size) else { break }
            buffer.moveReaderIndex(forwardBy: 4)
            let data = Data(buffer.readBytes(length: Int(size))!)
            do {
                guard queuedCount < 16, queuedBytes + data.count <= 1024 * 1024 else { throw SecureError.protocolViolation }
                let packet = try JSONDecoder().decode(SecurePacket.self, from: data)
                queuedCount += 1; queuedBytes += data.count
                onPacket(packet) { context.eventLoop.execute { self.queuedCount -= 1; self.queuedBytes -= data.count } }
            }
            catch { context.close(promise: nil); return }
        }
        buffer.discardReadBytes()
    }
    func channelInactive(context: ChannelHandlerContext) { timeout?.cancel(); onClose(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

@MainActor final class SecureTransport {
    private var channel: Channel?
    private var authenticationContext: LAContext?
    private var generation = UUID()
    private var readyPeer: Data?
    private var authenticated = false
    private var pendingBytes = 0
    private var pendingCount = 0
    var onReady: ((Data) -> Void)?
    var onPacket: ((SecurePacket) -> Void)?
    var onClose: (() -> Void)?
    func connect(base: URL, path: String, token: String, identity: DeviceIdentity, server: Bool, authenticationContext: LAContext? = nil,
                 accepts: @escaping (Data) -> Bool) async throws {
        close(); let current = UUID(); generation = current
        let context = authenticationContext ?? LAContext(); self.authenticationContext = context
        let tlsContext = try NIOSSLContext(configuration: identity.tlsConfiguration(server: server, authenticationContext: context))
        let bridge = WebSocketBytes()
        let records = SecureRecords(onReady: { [weak self] peer in
            DispatchQueue.main.async { MainActor.assumeIsolated { guard let self, self.generation == current else { return }; self.readyPeer = peer; self.deliverReady() } }
        }, onPacket: { [weak self] packet, done in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                defer { done() }; guard let self, self.generation == current else { return }; self.onPacket?(packet)
            } }
        }, onClose: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { guard let self, self.generation == current else { return }; self.close(); self.onClose?() } }
        })
        var outerConfig = TLSConfiguration.makeClientConfiguration()
        outerConfig.minimumTLSVersion = .tlsv13
        let outerContext = base.scheme == "https" ? try NIOSSLContext(configuration: outerConfig) : nil
        let host = base.host!
        let negotiation: EventLoopFuture<Channel> = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.writeBufferWaterMark, value: ChannelOptions.Types.WriteBufferWaterMark(low: 64 * 1024, high: 1024 * 1024))
            .connect(host: host, port: base.port ?? (base.scheme == "https" ? 443 : 80)) { [weak self] channel in
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self, self.generation == current else { channel.close(promise: nil); return }
                    self.channel = channel
                } }
                return channel.eventLoop.makeCompletedFuture {

                    if let outerContext { try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: outerContext, serverHostname: host)) }
                    let upgrader = NIOTypedWebSocketClientUpgrader<Channel>(maxFrameSize: 65536, upgradePipelineHandler: { channel, _ in
                        channel.eventLoop.makeCompletedFuture {

                            try channel.pipeline.syncOperations.addHandler(bridge)
                            let inner = try DeviceTLS.handler(context: tlsContext, server: server, accepts: accepts, verified: { records.peer = $0 })
                            let gate = PeerProtocolGate()
                            // Records must observe the handshake event; TLS is inserted last, before records.
                            try channel.pipeline.syncOperations.addHandler(records)
                            try channel.pipeline.syncOperations.addHandler(gate, position: .before(records))
                            try channel.pipeline.syncOperations.addHandler(inner, position: .before(gate))
                            return channel
                        }
                    })
                    var headers = HTTPHeaders()
                    headers.add(name: "Host", value: base.port == nil ? host : "\(host):\(base.port!)")
                    headers.add(name: "Authorization", value: "Bearer \(token)")
                    headers.add(name: "Content-Length", value: "0")
                    let request = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/" + path, headers: headers)
                    let config = NIOTypedHTTPClientUpgradeConfiguration(upgradeRequestHead: request, upgraders: [upgrader], notUpgradingCompletionHandler: { channel in
                        channel.close(promise: nil); return channel.eventLoop.makeFailedFuture(SecureError.protocolViolation)
                    })
                    var pipeline = NIOUpgradableHTTPClientPipelineConfiguration(upgradeConfiguration: config)
                    // The relay may send the first TLS frame in the same read as HTTP 101.
                    pipeline.leftOverBytesStrategy = .forwardBytes
                    let result = try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(configuration: pipeline)
                    let timeout = channel.eventLoop.scheduleTask(in: .seconds(60)) { channel.close(promise: nil) }
                    result.whenComplete { _ in timeout.cancel() }
                    return result
                }
            }
        let connected = try await negotiation.get()
        try await connected.eventLoop.submit { bridge.activate() }.get()
        guard generation == current else { try? await connected.close().get(); throw SecureError.disconnected }
        channel = connected; deliverReady()
    }
    private func deliverReady() { if channel != nil, let peer = readyPeer { readyPeer = nil; authenticated = true; onReady?(peer) } }
    func send(_ packet: SecurePacket) {
        guard authenticated, let channel else { close(); onClose?(); return }
        do {
            let data = try JSONEncoder().encode(packet)
            guard data.count <= 512 * 1024, pendingCount < 16, pendingBytes + data.count <= 1024 * 1024 else { close(); onClose?(); return }
            var bytes = channel.allocator.buffer(capacity: data.count + 4)
            bytes.writeInteger(UInt32(data.count)); bytes.writeBytes(data)
            pendingCount += 1; pendingBytes += data.count
            let current = generation
            channel.writeAndFlush(bytes).whenComplete { [weak self] result in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    self.pendingCount -= 1; self.pendingBytes -= data.count
                    if case .failure = result { self.close(); self.onClose?() }
                }
            }
        } catch { close(); onClose?() }
    }
    func close() { authenticationContext?.invalidate(); authenticationContext = nil; generation = UUID(); channel?.close(promise: nil); channel = nil; readyPeer = nil; authenticated = false; pendingBytes = 0; pendingCount = 0 }
}
