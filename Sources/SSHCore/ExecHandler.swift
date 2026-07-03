import NIOCore
import NIOSSH

/// Barnkanal-handler för ett `exec`-kommando. Slår om ByteBuffer <-> SSHChannelData
/// och strömmar stdout/stderr till en AsyncThrowingStream. Kör på barnkanalens
/// event loop.
final class ExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let continuation: AsyncThrowingStream<SSHChunk, Error>.Continuation
    private var exitStatus: Int?

    init(command: String, continuation: AsyncThrowingStream<SSHChunk, Error>.Continuation) {
        self.command = command
        self.continuation = continuation
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Tillåt att servern stänger sin halva när kommandot är klart.
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelActive(context: ChannelHandlerContext) {
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
        context.triggerUserOutboundEvent(exec, promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buf) = channelData.data else { return }
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes) ?? []
        let stream: SSHChunk.Stream = channelData.type == .stdErr ? .stderr : .stdout
        continuation.yield(SSHChunk(stream: stream, bytes: bytes))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus = Int(status.exitStatus)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let s = exitStatus, s != 0 {
            continuation.finish(throwing: SSHError.remoteExit(status: s))
        } else {
            continuation.finish()
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }

    // stdin: ByteBuffer -> SSHChannelData
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buf))
        context.write(wrapOutboundOut(wrapped), promise: promise)
    }
}
