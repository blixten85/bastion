import Crypto
import NIOCore
import NIOPosix
import NIOSSH

// En minimal SSH-server i processen, enbart för test. Accepterar ett lösenord
// och svarar på exec-förfrågningar med "ran: <kommando>\n" + exit 0.

final class ServerAuth: NIOSSHServerUserAuthenticationDelegate {
    let password: String
    init(password: String) { self.password = password }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
        [.password, .publicKey]
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        switch request.request {
        case .password(let p):
            responsePromise.succeed(p.password == password ? .success : .failure)
        case .publicKey:
            // NIOSSH har redan verifierat signaturen; testservern godtar nyckeln.
            responsePromise.succeed(.success)
        default:
            responsePromise.succeed(.failure)
        }
    }
}

final class ServerExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private var shellMode = false

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exec = event as? SSHChannelRequestEvent.ExecRequest {
            var buf = context.channel.allocator.buffer(capacity: 32)
            buf.writeString("ran: \(exec.command)\n")
            let data = SSHChannelData(type: .channel, data: .byteBuffer(buf))
            context.writeAndFlush(wrapOutboundOut(data), promise: nil)
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0), promise: nil)
            context.close(promise: nil)
        } else if event is SSHChannelRequestEvent.ShellRequest {
            // Enkel "echo-shell": speglar all stdin tillbaka som stdout.
            shellMode = true
        }
        // PseudoTerminalRequest ignoreras (accepteras implicit).
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard shellMode else { return }
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer = channelData.data else { return }
        context.writeAndFlush(wrapOutboundOut(channelData), promise: nil)
    }
}

/// Server-sidans direct-tcpip-handler för test: ekar bara tillbaka precis vad
/// den tar emot, oavsett vilken targetHost/targetPort klienten bad om. Räcker
/// för att bevisa hela portvidarebefordrings-vägen (lokal TCP -> SSH-kanal ->
/// tillbaka) utan att behöva ett riktigt nätverksmål.
final class ServerDirectTCPIPEchoHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

struct LoopbackServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    var port: Int { channel.localAddress?.port ?? 0 }

    static func start(password: String) throws -> LoopbackServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    NIOSSHHandler(
                        role: .server(.init(
                            hostKeys: [hostKey],
                            userAuthDelegate: ServerAuth(password: password))),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, channelType in
                            switch channelType {
                            case .directTCPIP:
                                return child.pipeline.addHandler(ServerDirectTCPIPEchoHandler())
                            default:
                                return child.pipeline.addHandler(ServerExecHandler())
                            }
                        }))
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        return LoopbackServer(group: group, channel: channel)
    }

    func shutdown() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }
}
