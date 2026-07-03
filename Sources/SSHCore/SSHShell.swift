import NIOCore
import NIOSSH

/// En interaktiv shell över SSH: PTY + shell-kanal. `output` strömmar allt
/// servern skriver; `send`/`resize` matar tangenttryck och fönsterändringar.
/// Detta är kanalen som driver en riktig terminalvy (SwiftTerm).
public final class SSHShell {
    private let channel: Channel
    public let output: AsyncThrowingStream<SSHChunk, Error>

    init(channel: Channel, output: AsyncThrowingStream<SSHChunk, Error>) {
        self.channel = channel
        self.output = output
    }

    /// Skicka rå indata (tangenttryck) till fjärr-shellen.
    public func send(_ bytes: [UInt8]) {
        var buf = channel.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        channel.writeAndFlush(buf, promise: nil)
    }

    public func send(_ text: String) {
        send(Array(text.utf8))
    }

    /// Meddela servern att terminalen ändrat storlek (SIGWINCH på fjärrsidan).
    public func resize(cols: Int, rows: Int) {
        let ev = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0)
        channel.triggerUserOutboundEvent(ev, promise: nil)
    }

    public func close() {
        channel.close(promise: nil)
    }
}

/// Barnkanal-handler för en interaktiv shell. Begär PTY + shell vid uppkoppling,
/// strömmar utdata och slår om ByteBuffer <-> SSHChannelData för indata.
final class ShellHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let term: String
    private let cols: Int
    private let rows: Int
    private let continuation: AsyncThrowingStream<SSHChunk, Error>.Continuation

    init(term: String, cols: Int, rows: Int,
         continuation: AsyncThrowingStream<SSHChunk, Error>.Continuation) {
        self.term = term
        self.cols = cols
        self.rows = rows
        self.continuation = continuation
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelActive(context: ChannelHandlerContext) {
        // wantReply: false — vi blockerar inte på bekräftelse; PTY allokeras ändå.
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false, term: term,
            terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))
        context.triggerUserOutboundEvent(pty, promise: nil)
        let shell = SSHChannelRequestEvent.ShellRequest(wantReply: false)
        context.triggerUserOutboundEvent(shell, promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buf) = channelData.data else { return }
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes) ?? []
        let stream: SSHChunk.Stream = channelData.type == .stdErr ? .stderr : .stdout
        continuation.yield(SSHChunk(stream: stream, bytes: bytes))
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }

    // indata: ByteBuffer -> SSHChannelData
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buf))
        context.write(wrapOutboundOut(wrapped), promise: promise)
    }
}
