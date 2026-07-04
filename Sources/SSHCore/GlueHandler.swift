import NIOCore

/// Bygger ihop två separata `Channel`-pipelines så data som kommer in på den
/// ena skrivs rakt igenom till den andra (och tvärtom). Används för att brygga
/// en lokal TCP-anslutning mot en SSH direct-tcpip-kanal vid portvidarebefordran.
///
/// Kopierad (med tillstånd, Apache 2.0) från swift-nio-ssh:s eget
/// `NIOSSHClient`-exempel — det är exempelkod i deras repo, inte del av det
/// publika NIOSSH-biblioteket, så den finns inte att importera direkt.
final class GlueHandler {
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead: Bool = false

    private init() {}

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }
}

extension GlueHandler {
    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerCloseFull() { context?.close(promise: nil) }
    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }
}

extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.partnerWrite(data) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.partnerCloseFull() }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { partner?.partnerCloseFull() }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}
