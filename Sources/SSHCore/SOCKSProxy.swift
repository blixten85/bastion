import NIOCore
import NIOPosix
import NIOSSH
import NIOConcurrencyHelpers

/// Fel under SOCKS5-handskakningen (RFC 1928). Skiljs från `SSHError` eftersom
/// de här felen aldrig når SSH-lagret — de uppstår helt lokalt, innan någon
/// `direct-tcpip`-kanal ens har begärts.
public enum SOCKSError: Error, CustomStringConvertible {
    case unsupportedVersion(UInt8)
    case noAcceptableAuthMethod
    case unsupportedCommand(UInt8)
    case unsupportedAddressType(UInt8)

    public var description: String {
        switch self {
        case .unsupportedVersion(let v): return "SOCKS: okänd version \(v) (stöder bara SOCKS5)"
        case .noAcceptableAuthMethod: return "SOCKS: klienten erbjöd ingen auth-metod utan lösenord (0x00)"
        case .unsupportedCommand(let c): return "SOCKS: kommando \(c) stöds inte (bara CONNECT/0x01)"
        case .unsupportedAddressType(let t): return "SOCKS: adresstyp \(t) stöds inte (bara IPv4/domännamn/IPv6)"
        }
    }
}

/// Ett avkodat SOCKS5 CONNECT-mål. Till skillnad från `-L`/`-R` (fast mål,
/// bestämt vid uppstart) väljs det här av klienten PER ANSLUTNING, i farten —
/// det är precis det som gör `-D` "dynamisk".
public struct SOCKSConnectRequest: Equatable {
    public let host: String
    public let port: Int
}

/// Lokal SOCKS5-handskakning på en nyss accepterad TCP-anslutning. Ackumulerar
/// inkommande bytes tills ett helt ramverk kan avkodas (TCP kan fragmentera
/// godtyckligt över flera `channelRead`-anrop) — först greeting, sedan
/// CONNECT-begäran. Efter en lyckad begäran anropas `onRequest` EN gång;
/// anroparen ansvarar för att ta bort den här handlern ur pipelinen och
/// koppla in en `GlueHandler` istället — SYNKRONT, INNAN SOCKS-svaret
/// skrivs (se `completeSOCKSConnect` nedan för varför ordningen spelar roll)
/// — `SOCKSHandshakeHandler` hanterar bara handskakningen, aldrig den
/// faktiska datareläningen.
final class SOCKSHandshakeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let handlerName = "socks-handshake"

    private enum State: CustomStringConvertible {
        case awaitingGreeting
        case awaitingRequest
        case done
        var description: String {
            switch self {
            case .awaitingGreeting: return "awaitingGreeting"
            case .awaitingRequest: return "awaitingRequest"
            case .done: return "done"
            }
        }
    }

    private var state: State = .awaitingGreeting
    private var buffer: ByteBuffer!
    private let onRequest: (SOCKSConnectRequest) -> Void
    private let onError: (Error) -> Void

    init(onRequest: @escaping (SOCKSConnectRequest) -> Void, onError: @escaping (Error) -> Void) {
        self.onRequest = onRequest
        self.onError = onError
    }

    func handlerAdded(context: ChannelHandlerContext) {
        buffer = context.channel.allocator.buffer(capacity: 0)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // `removeHandler` tar inte effekt omedelbart bara för att den
        // anropas — pipelinen kan hinna leverera ytterligare `channelRead`
        // till den här handlern INNAN borttagningen faktiskt slår igenom
        // (bevisat empiriskt: ett verkligt end-to-end-test misslyckades
        // tyst utan den här grenen). Måste alltså vidarebefordra rakt
        // igenom istället för att bara droppa — annars äts applikationsdata
        // som råkar komma in i det fönstret upp tyst, precis som den skulle
        // ha gjort om `GlueHandler` redan var på plats.
        guard state != .done else {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)

        do {
            if state == .awaitingGreeting {
                guard try consumeGreeting(context: context) else { return }
                state = .awaitingRequest
            }
            if state == .awaitingRequest {
                guard let request = try consumeRequest() else { return }
                state = .done
                onRequest(request)
            }
        } catch {
            state = .done
            onError(error)
        }
    }

    /// `true` = greeting konsumerad och svar skickat. `false` = väntar på mer data.
    private func consumeGreeting(context: ChannelHandlerContext) throws -> Bool {
        guard buffer.readableBytes >= 2,
              let version: UInt8 = buffer.getInteger(at: buffer.readerIndex),
              let nmethods: UInt8 = buffer.getInteger(at: buffer.readerIndex + 1)
        else { return false }
        guard buffer.readableBytes >= 2 + Int(nmethods) else { return false }

        guard version == 5 else { throw SOCKSError.unsupportedVersion(version) }
        buffer.moveReaderIndex(forwardBy: 2)
        let methods = buffer.readBytes(length: Int(nmethods)) ?? []
        guard methods.contains(0x00) else { throw SOCKSError.noAcceptableAuthMethod }

        var reply = context.channel.allocator.buffer(capacity: 2)
        reply.writeBytes([0x05, 0x00])
        context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
        return true
    }

    /// `nil` = väntar på mer data.
    private func consumeRequest() throws -> SOCKSConnectRequest? {
        guard buffer.readableBytes >= 4,
              let version: UInt8 = buffer.getInteger(at: buffer.readerIndex),
              let cmd: UInt8 = buffer.getInteger(at: buffer.readerIndex + 1),
              let atyp: UInt8 = buffer.getInteger(at: buffer.readerIndex + 3)
        else { return nil }
        guard version == 5 else { throw SOCKSError.unsupportedVersion(version) }
        guard cmd == 1 else { throw SOCKSError.unsupportedCommand(cmd) }

        let addrLength: Int
        switch atyp {
        case 0x01: addrLength = 4
        case 0x04: addrLength = 16
        case 0x03:
            guard buffer.readableBytes >= 5, let domainLen: UInt8 = buffer.getInteger(at: buffer.readerIndex + 4)
            else { return nil }
            addrLength = 1 + Int(domainLen)
        default:
            throw SOCKSError.unsupportedAddressType(atyp)
        }
        guard buffer.readableBytes >= 4 + addrLength + 2 else { return nil }

        buffer.moveReaderIndex(forwardBy: 4)
        let host: String
        switch atyp {
        case 0x01:
            let bytes = buffer.readBytes(length: 4)!
            host = bytes.map(String.init).joined(separator: ".")
        case 0x03:
            let len: UInt8 = buffer.readInteger()!
            host = buffer.readString(length: Int(len))!
        case 0x04:
            let bytes = buffer.readBytes(length: 16)!
            host = stride(from: 0, to: 16, by: 2)
                .map { String(format: "%02x%02x", bytes[$0], bytes[$0 + 1]) }
                .joined(separator: ":")
        default:
            throw SOCKSError.unsupportedAddressType(atyp)
        }
        let port: UInt16 = buffer.readInteger()!
        return SOCKSConnectRequest(host: host, port: Int(port))
    }
}

/// Ett aktivt dynamiskt portvidarebefordran (`ssh -D bindPort`, en lokal
/// SOCKS5-proxy). Varje ansluten SOCKS-klient (webbläsare, `curl --socks5`, …)
/// förhandlar SOCKS5 lokalt, och målet den begär vidarebefordras som en egen
/// `direct-tcpip`-SSH-kanal — precis som `-L`, men med målet valt av klienten
/// vid körning istället för fast vid uppstart.
public final class DynamicPortForward {
    private let serverChannel: Channel
    private let activeChannels: NIOLockedValueBox<[ObjectIdentifier: Channel]>
    public let bindHost: String
    public let bindPort: Int

    /// Faktiskt bunden lokal port — samma som `bindPort` om den var != 0,
    /// annars den OS-tilldelade porten (`bindPort: 0` = "valfri ledig port").
    public var actualBindPort: Int { serverChannel.localAddress?.port ?? bindPort }

    init(
        serverChannel: Channel, activeChannels: NIOLockedValueBox<[ObjectIdentifier: Channel]>,
        bindHost: String, bindPort: Int
    ) {
        self.serverChannel = serverChannel
        self.activeChannels = activeChannels
        self.bindHost = bindHost
        self.bindPort = bindPort
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
    /// Dynamisk portvidarebefordran, motsvarande `ssh -D bindPort`: startar en
    /// lokal SOCKS5-proxy på `bindHost:bindPort`. Varje ansluten klient
    /// förhandlar SOCKS5, och det mål den begär (valfritt, per anslutning)
    /// vidarebefordras som en `direct-tcpip`-SSH-kanal mot fjärrsidan.
    public func openDynamicPortForward(
        bindHost: String = "127.0.0.1",
        bindPort: Int
    ) async throws -> DynamicPortForward {
        guard let channel = self.channel else {
            throw SSHError.channelFailed("inte ansluten")
        }
        let sshHandler: NIOSSHHandler
        do {
            sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        } catch {
            throw SSHError.channelFailed(String(describing: error))
        }

        // Samma mönster som openLocalPortForward: skapas FÖRE bind(), inte
        // efteråt — annars kunde en klient hinna ansluta mellan bind() och
        // konstruktionen, och den anslutningen skulle aldrig spåras/stängas.
        let activeChannels = NIOLockedValueBox<[ObjectIdentifier: Channel]>([:])
        let serverChannel: Channel
        do {
            serverChannel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { inboundChannel in
                    let id = ObjectIdentifier(inboundChannel)
                    activeChannels.withLockedValue { $0[id] = inboundChannel }
                    inboundChannel.closeFuture.whenComplete { _ in
                        activeChannels.withLockedValue { _ = $0.removeValue(forKey: id) }
                    }
                    let handshake = SOCKSHandshakeHandler(
                        onRequest: { request in
                            Self.completeSOCKSConnect(
                                inboundChannel: inboundChannel, request: request, sshHandler: sshHandler)
                        },
                        onError: { _ in inboundChannel.close(promise: nil) }
                    )
                    return inboundChannel.pipeline.addHandler(handshake, name: SOCKSHandshakeHandler.handlerName)
                }
                .bind(host: bindHost, port: bindPort)
                .get()
        } catch {
            throw SSHError.channelFailed(String(describing: error))
        }

        return DynamicPortForward(
            serverChannel: serverChannel, activeChannels: activeChannels,
            bindHost: bindHost, bindPort: bindPort)
    }

    /// Öppnar `direct-tcpip`-kanalen mot SOCKS-klientens begärda mål och
    /// svarar med SOCKS5-svaret. Körs helt via future-kedjor (`.whenComplete`),
    /// aldrig genom en bryggad `async`-fortsättning — `channelPromise` skapas
    /// på `inboundChannel`s event loop, så dess callbacks garanterat kör där
    /// (samma resonemang som race-fixen i `PortForward.swift`, bara att här
    /// finns aldrig en `await`-brygga att undvika i första taget).
    private static func completeSOCKSConnect(
        inboundChannel: Channel, request: SOCKSConnectRequest, sshHandler: NIOSSHHandler
    ) {
        guard let originatorAddress = inboundChannel.remoteAddress else {
            inboundChannel.close(promise: nil)
            return
        }
        let channelPromise = inboundChannel.eventLoop.makePromise(of: Channel.self)
        let directTCPIP = SSHChannelType.DirectTCPIP(
            targetHost: request.host, targetPort: request.port,
            originatorAddress: originatorAddress
        )
        sshHandler.createChannel(channelPromise, channelType: .directTCPIP(directTCPIP)) { childChannel, channelType in
            guard case .directTCPIP = channelType else {
                return inboundChannel.eventLoop.makeFailedFuture(SSHError.channelFailed("fel kanaltyp"))
            }
            return childChannel.eventLoop.makeCompletedFuture {
                try childChannel.pipeline.syncOperations.addHandler(DirectTCPIPWrapperHandler())
            }
        }

        channelPromise.futureResult.whenComplete { result in
            switch result {
            case .success(let sshChildChannel):
                // Bytt ur SOCKS-handskakningshandlern och kopplar in
                // glue-paret SYNKRONT, INNAN svaret skrivs — inte efteråt.
                // `removeHandler` tar dock inte effekt omedelbart bara för
                // att den anropas (bevisat empiriskt av ett verkligt
                // end-to-end-test), så den ordningen räcker INTE ensam —
                // se `SOCKSHandshakeHandler.channelRead`s `fireChannelRead`-
                // gren ovan, som är den faktiska fixen för det fönstret.
                // Att installera glue-paret före svaret skrivs minimerar
                // ändå fönstret så mycket det går. `syncOperations` är
                // säkert här eftersom den här closuren garanterat kör på
                // `inboundChannel`s egen event loop (samma resonemang som
                // race-fixen i `PortForward.swift`).
                do {
                    try inboundChannel.pipeline.syncOperations.removeHandler(name: SOCKSHandshakeHandler.handlerName)
                    let (ours, theirs) = GlueHandler.matchedPair()
                    try inboundChannel.pipeline.syncOperations.addHandler(ours)
                    try sshChildChannel.pipeline.syncOperations.addHandler(theirs)
                } catch {
                    inboundChannel.close(promise: nil)
                    return
                }
                // REP 0x00 (lyckades), ATYP 0x01 (IPv4), BND.ADDR/PORT 0.0.0.0:0
                // — vi binder ingen egen socket (tunnlar bara), så en meningsfull
                // bind-adress finns inte; 0.0.0.0:0 är den vedertagna platshållaren.
                var reply = inboundChannel.allocator.buffer(capacity: 10)
                reply.writeBytes([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                inboundChannel.writeAndFlush(reply, promise: nil)
            case .failure:
                // REP 0x01 (generellt fel) — täcker in både avvisad anslutning
                // och andra createChannel-fel utan att försöka mappa varje
                // enskild orsak till en egen RFC 1928-kod.
                var reply = inboundChannel.allocator.buffer(capacity: 10)
                reply.writeBytes([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                inboundChannel.writeAndFlush(reply).whenComplete { _ in
                    inboundChannel.close(promise: nil)
                }
            }
        }
    }
}
