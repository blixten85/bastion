import NIOCore
import NIOPosix
import NIOSSH
import NIOConcurrencyHelpers

/// Slår om rå `ByteBuffer` <-> `SSHChannelData` på en direct-tcpip-barnkanal —
/// motsvarande `ExecHandler`, men utan kommando-/exitstatus-hantering (en
/// portvidarebefordrad kanal har varken).
final class DirectTCPIPWrapperHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .channel = data.type, case .byteBuffer(let buffer) = data.data else {
            context.fireErrorCaught(SSHError.channelFailed("oväntad kanaldata"))
            return
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))), promise: promise)
    }
}

/// Ett aktivt lokalt portvidarebefordran (`ssh -L bindPort:targetHost:targetPort`).
/// Håller den lokala TCP-lyssnaren vid liv — `close()` stänger den OCH alla
/// aktiva vidarebefordrade anslutningar (CodeRabbit-fynd, PR #25: close()
/// stängde tidigare bara lyssnaren, redan öppnade tunnlar fortsatte köra
/// tills fjärrsidan eller SSH-sessionen stängdes — kommentaren påstod
/// motsatsen).
public final class LocalPortForward {
    private let serverChannel: Channel
    private let activeChannels: NIOLockedValueBox<[ObjectIdentifier: Channel]>
    public let bindHost: String
    public let bindPort: Int
    public let targetHost: String
    public let targetPort: Int

    /// Faktiskt bunden lokal port — samma som `bindPort` om den var != 0,
    /// annars den OS-tilldelade porten (`bindPort: 0` = "valfri ledig port").
    public var actualBindPort: Int { serverChannel.localAddress?.port ?? bindPort }

    init(
        serverChannel: Channel, activeChannels: NIOLockedValueBox<[ObjectIdentifier: Channel]>,
        bindHost: String, bindPort: Int, targetHost: String, targetPort: Int
    ) {
        self.serverChannel = serverChannel
        self.activeChannels = activeChannels
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    public func close() async {
        let channels = activeChannels.withLockedValue { $0 }
        for (_, channel) in channels {
            try? await channel.close().get()
        }
        try? await serverChannel.close().get()
    }
}

extension SSHSession {
    /// Lokal portvidarebefordran, motsvarande `ssh -L bindPort:targetHost:targetPort`:
    /// startar en lokal TCP-lyssnare på `bindHost:bindPort`. Varje ansluten
    /// klient får en egen `direct-tcpip`-SSH-kanal mot `targetHost:targetPort`
    /// på fjärrsidan — datan bryggas rakt igenom (`GlueHandler`).
    public func openLocalPortForward(
        bindHost: String = "127.0.0.1",
        bindPort: Int,
        targetHost: String,
        targetPort: Int
    ) async throws -> LocalPortForward {
        guard let channel = self.channel else {
            throw SSHError.channelFailed("inte ansluten")
        }
        let sshHandler: NIOSSHHandler
        do {
            sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        } catch {
            throw SSHError.channelFailed(String(describing: error))
        }

        // Skapas FÖRE bind() (inte inuti LocalPortForward efteråt) — annars
        // kunde en klient hinna ansluta mellan att bind() returnerar och
        // LocalPortForward konstrueras, och den anslutningen skulle aldrig
        // spåras/stängas av close().
        let activeChannels = NIOLockedValueBox<[ObjectIdentifier: Channel]>([:])
        let serverChannel: Channel
        do {
            serverChannel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { inboundChannel in
                    guard let originatorAddress = inboundChannel.remoteAddress else {
                        return inboundChannel.eventLoop.makeFailedFuture(
                            SSHError.channelFailed("okänd avsändaradress"))
                    }
                    let id = ObjectIdentifier(inboundChannel)
                    activeChannels.withLockedValue { $0[id] = inboundChannel }
                    inboundChannel.closeFuture.whenComplete { _ in
                        activeChannels.withLockedValue { _ = $0.removeValue(forKey: id) }
                    }
                    let promise = inboundChannel.eventLoop.makePromise(of: Channel.self)
                    let directTCPIP = SSHChannelType.DirectTCPIP(
                        targetHost: targetHost, targetPort: targetPort,
                        originatorAddress: originatorAddress
                    )
                    sshHandler.createChannel(promise, channelType: .directTCPIP(directTCPIP)) { childChannel, channelType in
                        guard case .directTCPIP = channelType else {
                            return inboundChannel.eventLoop.makeFailedFuture(
                                SSHError.channelFailed("fel kanaltyp"))
                        }
                        return childChannel.eventLoop.makeCompletedFuture {
                            let (ours, theirs) = GlueHandler.matchedPair()
                            try childChannel.pipeline.syncOperations.addHandler(DirectTCPIPWrapperHandler())
                            try childChannel.pipeline.syncOperations.addHandler(ours)
                            try inboundChannel.pipeline.syncOperations.addHandler(theirs)
                        }
                    }
                    return promise.futureResult.map { _ in }
                }
                .bind(host: bindHost, port: bindPort)
                .get()
        } catch {
            throw SSHError.channelFailed(String(describing: error))
        }

        return LocalPortForward(
            serverChannel: serverChannel, activeChannels: activeChannels,
            bindHost: bindHost, bindPort: bindPort,
            targetHost: targetHost, targetPort: targetPort
        )
    }
}
