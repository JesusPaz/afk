import NIOCore
import NIOTLS

/// Install immediately after NIOSSL and before application framing/dispatch.
final class PeerProtocolGate: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    enum Failure: Error { case notAuthenticated, incompatibleProtocol }
    private var authenticated = false

    init() {}

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case let TLSUserEvent.handshakeCompleted(negotiatedProtocol) = event {
            guard negotiatedProtocol == DeviceTLS.applicationProtocol else {
                context.fireErrorCaught(Failure.incompatibleProtocol)
                context.close(promise: nil)
                return
            }
            authenticated = true
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard authenticated else {
            context.fireErrorCaught(Failure.notAuthenticated)
            context.close(promise: nil)
            return
        }
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard authenticated else {
            promise?.fail(Failure.notAuthenticated)
            return
        }
        context.write(data, promise: promise)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        authenticated = false
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        authenticated = false
        context.fireChannelInactive()
    }
}
