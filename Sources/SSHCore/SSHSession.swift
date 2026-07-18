import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// En SSH-anslutning. Anslut, kör kommandon (strömmad utdata), stäng.
/// Byggd rakt på SwiftNIO SSH — samma kod på Linux och Apple.
public final class SSHSession {
    private let target: SSHTarget
    private let auth: SSHAuth
    private let knownHosts: KnownHosts
    // internal (inte private) — PortForward.swifts SSHSession-extension i
    // samma modul behöver nå dem.
    let group: MultiThreadedEventLoopGroup
    // Bär ett fatalt fel som inträffar tyst under handshaken (NIOSSH stänger inte
    // alltid anslutningen vid misslyckad auth eller avvisad värdnyckel). När den
    // fullbordas avslutas pågående strömmar i stället för att hänga för evigt.
    private let fatal: EventLoopPromise<Error>
    private let fatalLock = NIOLock()
    private var fatalResolved = false
    var channel: Channel?

    // Fjärr-portvidarebefordran (ssh -R): servern öppnar en "forwarded-tcpip"-
    // kanal MOT klienten när någon ansluter till den fjärrport som begärts.
    // inboundChildChannelInitializer sätts en gång vid connect() (innan någon
    // openRemotePortForward()-anrop kan ha hunnit ske), så routningen måste gå
    // via en delad, trådsäker tabell istället för att fångas direkt i closuren.
    // Keyad enbart på port (inte host) — tillräckligt för det vanliga fallet
    // av en vidarebefordran per port, se PortForward.swift.
    let remoteForwards = NIOLockedValueBox<[Int: (targetHost: String, targetPort: Int)]>([:])

    public init(target: SSHTarget, auth: SSHAuth, knownHosts: KnownHosts = KnownHosts()) {
        self.target = target
        self.auth = auth
        self.knownHosts = knownHosts
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.fatal = group.next().makePromise(of: Error.self)
    }

    // fatal får bara fullbordas en gång (annars kraschar NIO). Första signalen
    // vinner — auth-give-up, avvisad värdnyckel eller close().
    private func signalFatal(_ error: Error) {
        let firstToResolve: Bool = fatalLock.withLock {
            if fatalResolved { return false }
            fatalResolved = true
            return true
        }
        if firstToResolve { fatal.succeed(error) }
    }

    // close() anropar signalFatal(...) synkront som sitt FÖRSTA steg, innan
    // den asynkrona nedstängningen (channel.close()/group.shutdownGracefully())
    // ens börjar. Den här flaggan låter openShell() (och annat som gör en
    // .get()-blockerande pipeline-uppslagning, till skillnad från execute()s
    // callback-baserade mönster som redan race:ar säkert mot closeFuture/fatal)
    // upptäcka en pågående/redan avslutad close() INNAN den rör en kanal vars
    // event loop-grupp kan hinna stängas ner under tiden — annars kraschar
    // processen med NIOs "leaking promise"-fatal error istället för att kasta
    // ett vanligt Swift-fel (reproducerat i TerminalTeardownRaceTests).
    private var isClosingOrClosed: Bool { fatalLock.withLock { fatalResolved } }

    /// Öppnar TCP + SSH-handshake + autentisering.
    public func connect() async throws {
        let userAuth = SSHUserAuth(username: target.username, auth: auth) { [weak self] in
            self?.signalFatal(SSHError.authenticationFailed)
        }
        let validator = TOFUHostKeyValidator(
            host: target.host, port: target.port, store: knownHosts
        ) { [weak self] info in
            self?.signalFatal(SSHError.hostKeyRejected(info))
        }
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [weak self] channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: userAuth,
                            serverAuthDelegate: validator)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { inboundChannel, channelType in
                            self?.handleInboundForwardedChannel(inboundChannel, channelType: channelType)
                                ?? inboundChannel.eventLoop.makeFailedFuture(
                                    SSHError.channelFailed("sessionen är borta"))
                        })
                ])
            }
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        do {
            channel = try await bootstrap.connect(host: target.host, port: target.port).get()
        } catch {
            throw SSHError.connectionFailed(String(describing: error))
        }
    }

    /// Ansluter GENOM en redan uppkopplad session (`ssh -J`/ProxyJump) —
    /// istället för en ny TCP-anslutning öppnas en `direct-tcpip`-kanal från
    /// `jump` till DEN HÄR sessionens mål, och en helt egen, oberoende SSH-
    /// handskakning (egen `NIOSSHHandler`, eget `SSHUserAuth`/TOFU) körs
    /// direkt ovanpå den kanalen — samma "SSH i SSH"-mönster som en riktig
    /// `ssh -J` gör på trådnivå. `jump` måste redan vara ansluten.
    ///
    /// **Viktigt om stängningsordning**: den här sessionens kanal lever på
    /// `jump`s event loop-grupp (inte sin egen — `self.group` skapas i
    /// `init()` men används aldrig här, precis som vanligt är det ofarligt
    /// att stänga). Stäng DÄRFÖR alltid den här sessionen INNAN `jump`
    /// stängs — tvärtom (stänga `jump` medan den här sessionen fortfarande
    /// är öppen) gör att `jump`s event loop-grupp redan är nedstängd när den
    /// här sessionens `close()` försöker schemalägga sin egen kanalstängning
    /// på den, vilket hänger/misslyckas tyst (bevisat empiriskt: en tidig
    /// testversion med fel ordning hängde processen). Motsvarar för övrigt
    /// exakt hur en riktig `ssh -J` fungerar — dör tunneln (jump), dör allt
    /// som går genom den.
    public func connect(via jump: SSHSession) async throws {
        guard let jumpChannel = jump.channel else {
            throw SSHError.channelFailed("jump-sessionen är inte ansluten")
        }
        let jumpSSHHandler: NIOSSHHandler
        do {
            jumpSSHHandler = try await jumpChannel.pipeline.handler(type: NIOSSHHandler.self).get()
        } catch {
            throw SSHError.channelFailed(String(describing: error))
        }
        guard let originatorAddress = jumpChannel.localAddress else {
            throw SSHError.channelFailed("okänd lokal adress på jump-sessionen")
        }

        let userAuth = SSHUserAuth(username: target.username, auth: auth) { [weak self] in
            self?.signalFatal(SSHError.authenticationFailed)
        }
        let validator = TOFUHostKeyValidator(
            host: target.host, port: target.port, store: knownHosts
        ) { [weak self] info in
            self?.signalFatal(SSHError.hostKeyRejected(info))
        }

        let directTCPIP = SSHChannelType.DirectTCPIP(
            targetHost: target.host, targetPort: target.port, originatorAddress: originatorAddress)
        let childPromise = jumpChannel.eventLoop.makePromise(of: Channel.self)
        jumpSSHHandler.createChannel(childPromise, channelType: .directTCPIP(directTCPIP)) { [weak self] child, channelType in
            guard case .directTCPIP = channelType else {
                return jumpChannel.eventLoop.makeFailedFuture(SSHError.channelFailed("fel kanaltyp"))
            }
            return child.eventLoop.makeCompletedFuture {
                try child.pipeline.syncOperations.addHandler(DirectTCPIPWrapperHandler())
                try child.pipeline.syncOperations.addHandler(NIOSSHHandler(
                    role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: validator)),
                    allocator: child.allocator,
                    inboundChildChannelInitializer: { inboundChannel, channelType in
                        self?.handleInboundForwardedChannel(inboundChannel, channelType: channelType)
                            ?? inboundChannel.eventLoop.makeFailedFuture(
                                SSHError.channelFailed("sessionen är borta"))
                    }))
            }
        }
        do {
            channel = try await childPromise.futureResult.get()
        } catch {
            throw SSHError.connectionFailed(String(describing: error))
        }
    }

    /// Kör ett kommando och strömmar stdout/stderr allteftersom det kommer.
    /// Kastar `SSHError.remoteExit` om exitkoden är != 0.
    public func execute(_ command: String) -> AsyncThrowingStream<SSHChunk, Error> {
        AsyncThrowingStream { continuation in
            guard let channel = self.channel else {
                continuation.finish(throwing: SSHError.channelFailed("inte ansluten"))
                return
            }
            // Om hela anslutningen stängs (t.ex. misslyckad autentisering sker
            // asynkront efter TCP-connect) avslutas strömmen med fel i stället
            // för att hänga. finish() är idempotent — en normalt avslutad ström
            // påverkas inte när vi själva stänger senare.
            channel.closeFuture.whenComplete { _ in
                continuation.finish(throwing: SSHError.channelFailed("anslutningen stängdes"))
            }
            // Tyst handshake-fel (auth eller avvisad värdnyckel): avsluta med felet.
            self.fatal.futureResult.whenSuccess { continuation.finish(throwing: $0) }
            channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
                switch result {
                case .failure(let e):
                    continuation.finish(throwing: SSHError.channelFailed(String(describing: e)))
                case .success(let sshHandler):
                    let promise = channel.eventLoop.makePromise(of: Channel.self)
                    sshHandler.createChannel(promise, channelType: .session) { child, _ in
                        child.pipeline.addHandler(
                            ExecHandler(command: command, continuation: continuation))
                    }
                    promise.futureResult.whenFailure { e in
                        continuation.finish(throwing: SSHError.channelFailed(String(describing: e)))
                    }
                }
            }
        }
    }

    /// Öppnar en interaktiv shell med PTY. Returnerar ett handtag att skriva
    /// tangenttryck till och läsa strömmad utdata ifrån — det som driver en
    /// terminalvy.
    public func openShell(
        term: String = "xterm-256color", cols: Int = 80, rows: Int = 24
    ) async throws -> SSHShell {
        guard let channel = self.channel, !isClosingOrClosed else {
            throw SSHError.channelFailed("inte ansluten")
        }

        var cont: AsyncThrowingStream<SSHChunk, Error>.Continuation!
        let stream = AsyncThrowingStream<SSHChunk, Error> { cont = $0 }
        let continuation = cont!

        // Om anslutningen stängs eller handshaken fallerar avslutas shell-strömmen.
        channel.closeFuture.whenComplete { _ in continuation.finish() }
        self.fatal.futureResult.whenSuccess { continuation.finish(throwing: $0) }

        // isClosingOrClosed ovan är bara en preflight-koll (TOCTOU) — en
        // close() kan fortfarande starta EFTER den men INNAN
        // pipeline-uppslagningen nedan hinner svara, vilket river ner
        // event loop-gruppen medan ett promise på den fortfarande är
        // öppet (NIOs "leaking promise"-krasch). Precis som execute()
        // löser vi det genom att registrera closeFuture/fatal-lyssnare
        // som race:ar mot pipeline-uppslagningen via callbacks istället
        // för en naken `try await ...get()`, och låta EN gemensam,
        // låsskyddad flagga avgöra vem som får fullborda resultatet.
        let resultPromise = channel.eventLoop.makePromise(of: SSHShell.self)
        let resolveLock = NIOLock()
        var resolved = false
        func resolveOnce(_ body: () -> Void) {
            let shouldRun: Bool = resolveLock.withLock {
                if resolved { return false }
                resolved = true
                return true
            }
            if shouldRun { body() }
        }

        self.fatal.futureResult.whenSuccess { error in
            resolveOnce { resultPromise.fail(error) }
        }
        channel.closeFuture.whenComplete { _ in
            resolveOnce { resultPromise.fail(SSHError.channelFailed("inte ansluten")) }
        }
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            resolveOnce {
                switch result {
                case .failure(let e):
                    resultPromise.fail(SSHError.channelFailed(String(describing: e)))
                case .success(let sshHandler):
                    let handler = ShellHandler(term: term, cols: cols, rows: rows, continuation: continuation)
                    let childPromise = channel.eventLoop.makePromise(of: Channel.self)
                    sshHandler.createChannel(childPromise, channelType: .session) { child, _ in
                        child.pipeline.addHandler(handler)
                    }
                    // Redan "vunnet" ovan (resolved == true) — den här
                    // fullbordar samma, redan reserverade resultat, inte
                    // en ny tävling.
                    childPromise.futureResult.whenComplete { childResult in
                        switch childResult {
                        case .failure(let e):
                            resultPromise.fail(SSHError.channelFailed(String(describing: e)))
                        case .success(let child):
                            resultPromise.succeed(SSHShell(channel: child, output: stream))
                        }
                    }
                }
            }
        }

        return try await resultPromise.futureResult.get()
    }

    /// Bekvämlighet: samla hela utdatan till en sträng.
    public func run(_ command: String) async throws -> String {
        var out = ""
        for try await chunk in execute(command) {
            out += chunk.text
        }
        return out
    }

    public func close() async {
        signalFatal(SSHError.channelFailed("stängd"))
        try? await channel?.close().get()
        try? await group.shutdownGracefully()
    }
}

/// En anslutningskedja: en target-session, ev. GENOM en jump-session
/// (`ssh -J`/ProxyJump). Håller ihop de två så att anroparen (App-lagret,
/// t.ex. `SSHTerminalController`) aldrig själv behöver komma ihåg den
/// dokumenterade stängningsordningen (target FÖRE jump, se doc-kommentaren
/// på `SSHSession.connect(via:)` ovan).
public final class SSHConnectionChain {
    public let target: SSHSession
    /// Jump-sessionen, om en användes. **Stäng ALDRIG denna direkt** — den
    /// måste stängas EFTER `target` (se doc-kommentaren på `connect(via:)`
    /// ovan). Använd alltid `chain.close()`, som garanterar rätt ordning.
    public let jump: SSHSession?

    private init(target: SSHSession, jump: SSHSession?) {
        self.target = target
        self.jump = jump
    }

    /// Ansluter `target` direkt om `jump` är `nil`. Annars ansluts `jump`
    /// FÖRST, och `target` kopplas GENOM den (`connect(via:)`). Varje
    /// misslyckande-väg stänger allt som redan hunnit skapas/anslutas —
    /// annars läcker sessionens "fatal"-promise (NIOs läckagedetektor
    /// kraschar processen i debug-läge, se testerna i ProxyJumpTests.swift
    /// som bevisar detta för respektive väg).
    public static func connect(
        target targetEndpoint: SSHTarget,
        targetAuth: SSHAuth,
        jump jumpEndpoint: (target: SSHTarget, auth: SSHAuth)?,
        knownHosts: KnownHosts = KnownHosts()
    ) async throws -> SSHConnectionChain {
        let targetSession = SSHSession(target: targetEndpoint, auth: targetAuth, knownHosts: knownHosts)
        guard let jumpEndpoint else {
            do {
                try await targetSession.connect()
            } catch {
                await targetSession.close()
                throw error
            }
            return SSHConnectionChain(target: targetSession, jump: nil)
        }
        let jumpSession = SSHSession(target: jumpEndpoint.target, auth: jumpEndpoint.auth, knownHosts: knownHosts)
        do {
            try await jumpSession.connect()
        } catch {
            // targetSession hann aldrig ansluta/skapa en kanal, men dess egen
            // "fatal"-promise (skapad redan i init()) måste ändå upplösas.
            await targetSession.close()
            await jumpSession.close()
            throw error
        }
        do {
            try await targetSession.connect(via: jumpSession)
        } catch {
            // Stäng target FÖRE jump (samma dokumenterade ordning som close()
            // nedan) — annars läcker targetSessions egen "fatal"-promise (se
            // testConnectViaUnconnectedJumpThrows för samma resonemang).
            await targetSession.close()
            await jumpSession.close()
            throw error
        }
        return SSHConnectionChain(target: targetSession, jump: jumpSession)
    }

    /// Stänger i rätt ordning: target FÖRE jump.
    public func close() async {
        await target.close()
        await jump?.close()
    }
}
