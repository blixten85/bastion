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

/// Ett aktivt fjärr-portvidarebefordran (`ssh -R bindPort:targetHost:targetPort`):
/// servern lyssnar åt oss, och vidarebefordrar inkommande anslutningar till oss
/// som `forwarded-tcpip`-kanaler, som vi i sin tur bryggar mot en lokal
/// TCP-anslutning till `targetHost:targetPort` (sett från klientens sida, till
/// skillnad från `LocalPortForward` där målet ligger på fjärrsidan).
public final class RemotePortForward {
    private weak var session: SSHSession?
    public let bindHost: String
    /// Porten som begärdes (kan vara 0 = "valfri ledig port hos servern").
    public let bindPort: Int
    /// Porten servern faktiskt band — samma som `bindPort` om den inte var 0.
    public let actualBindPort: Int
    public let targetHost: String
    public let targetPort: Int

    init(session: SSHSession, bindHost: String, bindPort: Int, actualBindPort: Int, targetHost: String, targetPort: Int) {
        self.session = session
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.actualBindPort = actualBindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    /// Ber servern sluta vidarebefordra och tar bort routningen lokalt.
    /// Best-effort (samma som `LocalPortForward.close()`s `try?`-mönster) —
    /// om sessionen redan är stängd/borta finns inget att avbeställa.
    public func close() async {
        guard let session, let channel = session.channel else { return }
        session.remoteForwards.withLockedValue { $0.removeValue(forKey: actualBindPort) }
        guard let sshHandler = try? await channel.pipeline.handler(type: NIOSSHHandler.self).get() else { return }
        let promise = channel.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
        // sendTCPForwardingRequest är dokumenterat "inte trådsäker, får bara
        // anropas på kanalens egen event loop" — en async-fortsättning
        // garanterar INTE att vi fortfarande kör där, så själva anropet måste
        // skickas in explicit via eventLoop.execute (kraschade annars med
        // "Precondition failed" i assumeIsolatedUnsafeUnchecked).
        channel.eventLoop.execute {
            sshHandler.sendTCPForwardingRequest(.cancel(host: self.bindHost, port: self.actualBindPort), promise: promise)
        }
        _ = try? await promise.futureResult.get()
    }
}

extension SSHSession {
    /// Fjärr-portvidarebefordran, motsvarande `ssh -R bindPort:targetHost:targetPort`:
    /// ber servern lyssna på `bindHost:bindPort` på sin sida. Varje anslutning
    /// dit ger en `forwarded-tcpip`-kanal tillbaka till oss (dirigerad via
    /// `remoteForwards`, se `handleInboundForwardedChannel`), som bryggas mot
    /// en ny lokal TCP-anslutning till `targetHost:targetPort`.
    public func openRemotePortForward(
        bindHost: String = "0.0.0.0",
        bindPort: Int,
        targetHost: String,
        targetPort: Int
    ) async throws -> RemotePortForward {
        guard let channel = self.channel else {
            throw SSHError.channelFailed("inte ansluten")
        }
        let sshHandler: NIOSSHHandler
        do {
            sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        } catch {
            throw SSHError.channelFailed(String(describing: error))
        }

        let promise = channel.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
        // Se kommentaren i RemotePortForward.close() — samma icke-trådsäkra
        // anrop, samma behov av att explicit köra på kanalens event loop.
        channel.eventLoop.execute {
            sshHandler.sendTCPForwardingRequest(.listen(host: bindHost, port: bindPort), promise: promise)
        }
        // Registreras INUTI future-kedjan (flatMapThrowing), inte efter att
        // await bridgat till async — en async-fortsättning kan återupptas på
        // vilken tråd som helst, medan en inkommen forwarded-tcpip-kanal
        // dispatchas på kanalens event loop-tråd. Utan det här fanns ett
        // fönster där en anslutning hann in innan mappningen skrevs, och
        // avvisades som "ingen aktiv fjärrvidarebefordran" (CodeRabbit-fynd).
        // flatMapThrowings closure körs garanterat på future:ns egen event
        // loop, precis som handleInboundForwardedChannel dispatchas på.
        let actualBindPort: Int
        do {
            actualBindPort = try await promise.futureResult.flatMapThrowing { [remoteForwards] response in
                // Om bindPort var 0 ("valfri ledig port") berättar servern
                // vilken port den faktiskt band i svaret — annars är det
                // samma som begärt.
                let port = response?.boundPort ?? bindPort
                remoteForwards.withLockedValue { $0[port] = (targetHost: targetHost, targetPort: targetPort) }
                return port
            }.get()
        } catch {
            // Servern kan sakna stöd för fjärr-portvidarebefordran helt
            // (AllowTcpForwarding no), eller ha avvisat begäran — samma
            // felkategori som andra kanalfel, inget eget behövs.
            throw SSHError.channelFailed(String(describing: error))
        }

        return RemotePortForward(
            session: self, bindHost: bindHost, bindPort: bindPort, actualBindPort: actualBindPort,
            targetHost: targetHost, targetPort: targetPort
        )
    }

    /// Kallas av `inboundChildChannelInitializer` (se `connect()`) för varje
    /// kanal fjärrsidan öppnar mot oss. Bara `forwarded-tcpip` med en port som
    /// finns i `remoteForwards` accepteras — allt annat avvisas.
    func handleInboundForwardedChannel(_ inboundChannel: Channel, channelType: SSHChannelType) -> EventLoopFuture<Void> {
        guard case .forwardedTCPIP(let info) = channelType else {
            return inboundChannel.eventLoop.makeFailedFuture(
                SSHError.channelFailed("oväntad kanaltyp för inkommande fjärrvidarebefordran"))
        }
        guard let target = remoteForwards.withLockedValue({ $0[info.listeningPort] }) else {
            return inboundChannel.eventLoop.makeFailedFuture(
                SSHError.channelFailed("ingen aktiv fjärrvidarebefordran för port \(info.listeningPort)"))
        }

        return ClientBootstrap(group: group)
            .connect(host: target.targetHost, port: target.targetPort)
            .flatMap { localChannel in
                localChannel.eventLoop.makeCompletedFuture {
                    // Wrappern hör hemma på SSH-kanalen (SSHChannelData-domän),
                    // INTE den lokala TCP-anslutningen (redan rå ByteBuffer) —
                    // fick dem omvända i ett tidigare försök, vilket kraschade
                    // med "tried to decode as type ByteBuffer but found
                    // SSHChannelData" så fort riktig data flödade igenom.
                    let (ours, theirs) = GlueHandler.matchedPair()
                    try localChannel.pipeline.syncOperations.addHandler(ours)
                    try inboundChannel.pipeline.syncOperations.addHandler(DirectTCPIPWrapperHandler())
                    try inboundChannel.pipeline.syncOperations.addHandler(theirs)
                }
            }
    }
}
