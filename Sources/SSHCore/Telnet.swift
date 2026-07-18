import NIOCore
import NIOPosix

/// En Telnet-anslutning (RFC 854) — rå TCP, INGEN kryptering. Ett protokoll
/// Termius stöder men Bastion helt saknade; relevant för äldre nätverksut-
/// rustning (switchar/routrar/UPS:er/seriell-över-nätverk-adaptrar) som bara
/// exponerar Telnet, inte SSH. Motsvarar `SSHShell` i gränssnitt (`output`/
/// `send`/`close`) men delar ingen kod med SSH-lagret — helt olika protokoll.
public struct TelnetTarget: Sendable {
    public var host: String
    public var port: Int
    public init(host: String, port: Int = 23) {
        self.host = host
        self.port = port
    }
}

public final class TelnetSession {
    private let channel: Channel
    private let group: MultiThreadedEventLoopGroup
    /// Redan rensat för IAC-förhandlingssekvenser — bara den faktiska
    /// terminalutdatan, precis som en användare skulle se den i en riktig
    /// telnet-klient.
    public let output: AsyncThrowingStream<[UInt8], Error>

    private init(channel: Channel, group: MultiThreadedEventLoopGroup, output: AsyncThrowingStream<[UInt8], Error>) {
        self.channel = channel
        self.group = group
        self.output = output
    }

    public static func connect(target: TelnetTarget) async throws -> TelnetSession {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var continuation: AsyncThrowingStream<[UInt8], Error>.Continuation!
        let stream = AsyncThrowingStream<[UInt8], Error> { continuation = $0 }
        do {
            let channel = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(TelnetIACHandler(continuation: continuation))
                }
                .connect(host: target.host, port: target.port).get()
            // Gruppen ägs av sessionen från och med nu — stängs i close(), inte
            // här. En misslyckad anslutning ovan har inget att stänga, se catch.
            return TelnetSession(channel: channel, group: group, output: stream)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func send(_ bytes: [UInt8]) {
        var buf = channel.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        channel.writeAndFlush(buf, promise: nil)
    }

    public func send(_ text: String) {
        send(Array(text.utf8))
    }

    public func close() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }
}

/// Ren state machine för Telnets IAC-förhandling (RFC 854/855) — ingen NIO,
/// enkelt att enhetstesta i isolering. Refuserar ALLTID varje förhandlat
/// alternativ (`WILL`→`DONT`, `DO`→`WONT`) i stället för att implementera
/// enskilda optioner (echo, terminal type, etc): enklast möjliga korrekta
/// klientbeteende — servern faller tillbaka till "rått" NVT-läge, som är
/// precis vad en enkel terminalvy vill ha. Subförhandlingar (`SB`...`SE`)
/// kastas bort helt av samma skäl (vi har inget alternativ att svara på).
final class TelnetIACFilter {
    private enum State {
        case data
        case sawIAC
        case sawNegotiationCommand(UInt8)
        case inSubnegotiation(sawIAC: Bool)
    }
    private var state: State = .data

    private static let IAC: UInt8 = 255
    private static let SE: UInt8 = 240
    private static let SB: UInt8 = 250
    private static let WILL: UInt8 = 251
    private static let WONT: UInt8 = 252
    private static let DO: UInt8 = 253
    private static let DONT: UInt8 = 254

    /// Bearbetar inkommande rådata. Returnerar den rensade nyttolasten
    /// (skickas vidare till appen) och ev. svarssekvenser (skickas tillbaka
    /// till servern, i den ordning de genererades).
    func process(_ input: [UInt8]) -> (data: [UInt8], replies: [UInt8]) {
        var data: [UInt8] = []
        var replies: [UInt8] = []
        for byte in input {
            switch state {
            case .data:
                if byte == Self.IAC { state = .sawIAC } else { data.append(byte) }
            case .sawIAC:
                switch byte {
                case Self.IAC:
                    // IAC IAC = en literal 0xFF-databyte, inte ett kommando.
                    data.append(Self.IAC)
                    state = .data
                case Self.WILL, Self.DO:
                    state = .sawNegotiationCommand(byte)
                case Self.WONT, Self.DONT:
                    state = .sawNegotiationCommand(byte)
                case Self.SB:
                    state = .inSubnegotiation(sawIAC: false)
                default:
                    // NOP/DM/BRK/IP/AO/AYT/EC/EL/GA m.fl. — inget optionsbyte,
                    // inget att svara på.
                    state = .data
                }
            case .sawNegotiationCommand(let command):
                switch command {
                case Self.WILL:
                    replies.append(contentsOf: [Self.IAC, Self.DONT, byte])
                case Self.DO:
                    replies.append(contentsOf: [Self.IAC, Self.WONT, byte])
                default:
                    break // WONT/DONT från servern kräver inget svar.
                }
                state = .data
            case .inSubnegotiation(let sawIAC):
                if sawIAC {
                    state = byte == Self.SE ? .data : .inSubnegotiation(sawIAC: false)
                } else {
                    state = byte == Self.IAC ? .inSubnegotiation(sawIAC: true) : .inSubnegotiation(sawIAC: false)
                }
            }
        }
        return (data, replies)
    }
}

/// Barnkanal-handler: kör inkommande bytes genom `TelnetIACFilter`, skickar
/// ev. svar direkt tillbaka, strömmar den rensade datan till appen.
final class TelnetIACHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let filter = TelnetIACFilter()
    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation

    init(continuation: AsyncThrowingStream<[UInt8], Error>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        let bytes = buf.readBytes(length: buf.readableBytes) ?? []
        let (clean, replies) = filter.process(bytes)
        if !replies.isEmpty {
            var replyBuf = context.channel.allocator.buffer(capacity: replies.count)
            replyBuf.writeBytes(replies)
            context.writeAndFlush(wrapOutboundOut(replyBuf), promise: nil)
        }
        if !clean.isEmpty {
            continuation.yield(clean)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}
