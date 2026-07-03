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
    private let group: MultiThreadedEventLoopGroup
    // Bär ett fatalt fel som inträffar tyst under handshaken (NIOSSH stänger inte
    // alltid anslutningen vid misslyckad auth eller avvisad värdnyckel). När den
    // fullbordas avslutas pågående strömmar i stället för att hänga för evigt.
    private let fatal: EventLoopPromise<Error>
    private let fatalLock = NIOLock()
    private var fatalResolved = false
    private var channel: Channel?

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
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: userAuth,
                            serverAuthDelegate: validator)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil)
                ])
            }
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        do {
            channel = try await bootstrap.connect(host: target.host, port: target.port).get()
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
        guard let channel = self.channel else {
            throw SSHError.channelFailed("inte ansluten")
        }
        let sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()

        var cont: AsyncThrowingStream<SSHChunk, Error>.Continuation!
        let stream = AsyncThrowingStream<SSHChunk, Error> { cont = $0 }
        let continuation = cont!

        // Om anslutningen stängs eller handshaken fallerar avslutas shell-strömmen.
        channel.closeFuture.whenComplete { _ in continuation.finish() }
        self.fatal.futureResult.whenSuccess { continuation.finish(throwing: $0) }

        let handler = ShellHandler(term: term, cols: cols, rows: rows, continuation: continuation)
        let childPromise = channel.eventLoop.makePromise(of: Channel.self)
        sshHandler.createChannel(childPromise, channelType: .session) { child, _ in
            child.pipeline.addHandler(handler)
        }
        let child = try await childPromise.futureResult.get()
        return SSHShell(channel: child, output: stream)
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
