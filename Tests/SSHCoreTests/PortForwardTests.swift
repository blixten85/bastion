import XCTest
import NIOCore
import NIOPosix
@testable import SSHCore

final class PortForwardTests: XCTestCase {
    /// Lokal portvidarebefordran end-to-end: en riktig lokal TCP-anslutning
    /// mot den lyssnare `openLocalPortForward` startar, genom en direct-tcpip
    /// SSH-kanal, till serverns eko-handler (se `LoopbackServer`), och tillbaka.
    func testLocalPortForwardEchoesThroughSSHChannel() async throws {
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }

        let session = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: server.port, username: "tester"),
            auth: .password("hunter2"), knownHosts: KnownHosts(path: nil))
        try await session.connect()

        let forward = try await session.openLocalPortForward(
            bindPort: 0, targetHost: "internal-target", targetPort: 9999)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        var received = ""
        let collector = ByteCollectorHandler()
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { channel in channel.pipeline.addHandler(collector) }
            .connect(host: "127.0.0.1", port: forward.actualBindPort)
            .get()

        var buf = client.allocator.buffer(capacity: 16)
        buf.writeString("hej genom tunneln")
        try await client.writeAndFlush(buf).get()

        // Vänta in ekot (kort poll — inget event att invänta explicit).
        for _ in 0..<50 {
            received = await collector.text()
            if received.contains("hej genom tunneln") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // Städa i rätt ordning (klient -> lyssnare -> session -> egen group) —
        // annars hinner NIOSSHs interna schemaläggning krocka med redan
        // nedstängda event loops.
        try? await client.close().get()
        await forward.close()
        await session.close()
        try? await group.shutdownGracefully()

        XCTAssertTrue(received.contains("hej genom tunneln"), "fick: \(received.debugDescription)")
    }
}

/// Samlar all inkommen text på en klientkanal (för test).
private final actor TextBox {
    private var text = ""
    func append(_ s: String) { text += s }
    func value() -> String { text }
}

private final class ByteCollectorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let box = TextBox()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        let s = String(buffer: buf)
        Task { await box.append(s) }
    }

    func text() async -> String { await box.value() }
}
