import NIOCore
import NIOTLS

/// Install immediately after NIOSSL and before application framing/dispatch.
public final class PeerProtocolGate: ChannelDuplexHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public enum Failure: Error { case notAuthenticated, incompatibleProtocol }
    private var authenticated = false

    public init() {}

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case let TLSUserEvent.handshakeCompleted(negotiatedProtocol) = event {
            guard negotiatedProtocol == PinnedTLS.applicationProtocol else {
                context.fireErrorCaught(Failure.incompatibleProtocol)
                context.close(promise: nil)
                return
            }
            authenticated = true
        }
        context.fireUserInboundEventTriggered(event)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard authenticated else {
            context.fireErrorCaught(Failure.notAuthenticated)
            context.close(promise: nil)
            return
        }
        context.fireChannelRead(data)
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard authenticated else {
            promise?.fail(Failure.notAuthenticated)
            return
        }
        context.write(data, promise: promise)
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        authenticated = false
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        authenticated = false
        context.fireChannelInactive()
    }
}
