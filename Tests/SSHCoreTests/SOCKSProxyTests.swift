import XCTest
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOConcurrencyHelpers
@testable import SSHCore

/// Ren protokollnivå — ingen SSH, ingen nätverksanslutning. `EmbeddedChannel`
/// låter oss mata in godtyckligt fragmenterade byte-sekvenser och inspektera
/// exakt vad handlern skriver ut, utan tajming-känslighet.
final class SOCKSHandshakeHandlerTests: XCTestCase {
    private func makeChannel() -> (EmbeddedChannel, requests: NIOLockedValueBox<[SOCKSConnectRequest]>, errors: NIOLockedValueBox<[Error]>) {
        let requests = NIOLockedValueBox<[SOCKSConnectRequest]>([])
        let errors = NIOLockedValueBox<[Error]>([])
        let handler = SOCKSHandshakeHandler(
            onRequest: { req in requests.withLockedValue { $0.append(req) } },
            onError: { err in errors.withLockedValue { $0.append(err) } }
        )
        let channel = EmbeddedChannel(handler: handler)
        return (channel, requests, errors)
    }

    func testGreetingRepliesNoAuthSelected() throws {
        let (channel, _, _) = makeChannel()
        var greeting = channel.allocator.buffer(capacity: 4)
        greeting.writeBytes([0x05, 0x01, 0x00])  // VER=5, NMETHODS=1, METHODS=[no-auth]
        try channel.writeInbound(greeting)

        let reply: ByteBuffer? = try channel.readOutbound()
        XCTAssertEqual(reply.map { Array($0.readableBytesView) }, [0x05, 0x00])
    }

    func testFullConnectRequestIPv4() throws {
        let (channel, requests, _) = makeChannel()
        var input = channel.allocator.buffer(capacity: 32)
        input.writeBytes([0x05, 0x01, 0x00])  // greeting
        input.writeBytes([0x05, 0x01, 0x00, 0x01])  // VER CMD=CONNECT RSV ATYP=IPv4
        input.writeBytes([93, 184, 216, 34])  // 93.184.216.34
        input.writeInteger(UInt16(443))
        try channel.writeInbound(input)

        _ = try channel.readOutbound(as: ByteBuffer.self)  // greeting-svaret, redan täckt ovan
        let all = requests.withLockedValue { $0 }
        XCTAssertEqual(all, [SOCKSConnectRequest(host: "93.184.216.34", port: 443)])
    }

    func testFullConnectRequestDomainName() throws {
        let (channel, requests, _) = makeChannel()
        var input = channel.allocator.buffer(capacity: 32)
        input.writeBytes([0x05, 0x01, 0x00])
        let domain = "example.com"
        input.writeBytes([0x05, 0x01, 0x00, 0x03])
        input.writeInteger(UInt8(domain.utf8.count))
        input.writeString(domain)
        input.writeInteger(UInt16(80))
        try channel.writeInbound(input)

        let all = requests.withLockedValue { $0 }
        XCTAssertEqual(all, [SOCKSConnectRequest(host: "example.com", port: 80)])
    }

    func testFullConnectRequestIPv6() throws {
        let (channel, requests, _) = makeChannel()
        var input = channel.allocator.buffer(capacity: 32)
        input.writeBytes([0x05, 0x01, 0x00])
        input.writeBytes([0x05, 0x01, 0x00, 0x04])
        input.writeBytes([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01])  // 2001:db8::1
        input.writeInteger(UInt16(22))
        try channel.writeInbound(input)

        let all = requests.withLockedValue { $0 }
        XCTAssertEqual(all, [SOCKSConnectRequest(host: "2001:0db8:0000:0000:0000:0000:0000:0001", port: 22)])
    }

    /// TCP ger inga meddelandegränser — handlern måste klara att greeting och
    /// begäran (och begäran i sig) kommer i godtyckligt många, godtyckligt
    /// små bitar över flera separata `channelRead`-anrop.
    func testFragmentedAcrossManyReads() throws {
        let (channel, requests, _) = makeChannel()
        var full = channel.allocator.buffer(capacity: 32)
        full.writeBytes([0x05, 0x01, 0x00])
        full.writeBytes([0x05, 0x01, 0x00, 0x01])
        full.writeBytes([10, 0, 0, 1])
        full.writeInteger(UInt16(8080))

        // Ett fragment i taget, en byte per `writeInbound`.
        while let byte: UInt8 = full.readInteger() {
            try channel.writeInbound(channel.allocator.buffer(bytes: [byte]))
        }

        let all = requests.withLockedValue { $0 }
        XCTAssertEqual(all, [SOCKSConnectRequest(host: "10.0.0.1", port: 8080)])
    }

    func testUnsupportedVersionErrors() throws {
        let (channel, _, errors) = makeChannel()
        var input = channel.allocator.buffer(capacity: 4)
        input.writeBytes([0x04, 0x01, 0x00])  // SOCKS4, inte 5
        try channel.writeInbound(input)

        let all = errors.withLockedValue { $0 }
        XCTAssertEqual(all.count, 1)
        guard case SOCKSError.unsupportedVersion(4) = all[0] else {
            return XCTFail("fel feltyp: \(all[0])")
        }
    }

    func testNoAcceptableAuthMethodErrors() throws {
        let (channel, _, errors) = makeChannel()
        var input = channel.allocator.buffer(capacity: 4)
        input.writeBytes([0x05, 0x01, 0x02])  // bara username/password (0x02), inget no-auth
        try channel.writeInbound(input)

        let all = errors.withLockedValue { $0 }
        guard case SOCKSError.noAcceptableAuthMethod = all.first ?? SOCKSError.unsupportedVersion(0) else {
            return XCTFail("förväntade noAcceptableAuthMethod, fick: \(all)")
        }
    }

    func testUnsupportedCommandErrors() throws {
        let (channel, _, errors) = makeChannel()
        var input = channel.allocator.buffer(capacity: 8)
        input.writeBytes([0x05, 0x01, 0x00])
        input.writeBytes([0x05, 0x02, 0x00, 0x01])  // CMD=0x02 (BIND), inte CONNECT
        input.writeBytes([0, 0, 0, 0])
        input.writeInteger(UInt16(0))
        try channel.writeInbound(input)

        let all = errors.withLockedValue { $0 }
        guard case SOCKSError.unsupportedCommand(2) = all.first ?? SOCKSError.unsupportedVersion(0) else {
            return XCTFail("förväntade unsupportedCommand(2), fick: \(all)")
        }
    }
}

/// Ekar rakt tillbaka — motsvarande mönster som `RemotePortForwardTests`s
/// `TCPEchoHandler`, men här är det bara för att bevisa att data flödar rätt
/// väg efter SOCKS-handskakningen, inte huvudpoängen med testet.
private final class TCPEchoHandler2: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

private final actor TextBox2 {
    private var text = ""
    func append(_ s: String) { text += s }
    func value() -> String { text }
}

private final class ByteCollectorHandler2: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let box = TextBox2()
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let s = String(buffer: unwrapInboundIn(data))
        Task { await box.append(s) }
    }
    func text() async -> String { await box.value() }
}

final class DynamicPortForwardTests: XCTestCase {
    /// End-to-end: en riktig SOCKS5-klient (handrullad, inget bibliotek)
    /// ansluter till den lokala SOCKS-proxyn, förhandlar SOCKS5, begär två
    /// OLIKA mål i tur och ordning — verifierar dels att servern faktiskt
    /// tog emot exakt de två targetHost/targetPort-paren (inte bara att data
    /// ekar, vilket `ServerDirectTCPIPEchoHandler` skulle göra oavsett mål),
    /// dels att data flödar rätt efter handskakningen.
    func testDynamicForwardRoutesDistinctTargetsAndEchoes() async throws {
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }

        let session = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: server.port, username: "tester"),
            auth: .password("hunter2"), knownHosts: KnownHosts(path: nil))
        try await session.connect()

        let forward = try await session.openDynamicPortForward(bindPort: 0)
        XCTAssertGreaterThan(forward.actualBindPort, 0)

        try await connectViaSOCKS(proxyPort: forward.actualBindPort, targetHost: "203.0.113.5", targetPort: 51_000)
        try await connectViaSOCKS(proxyPort: forward.actualBindPort, targetHost: "example.org", targetPort: 8080)

        await forward.close()
        await session.close()

        let observed = server.observedDirectTCPIPTargets.withLockedValue { $0 }
        XCTAssertEqual(observed.count, 2)
        XCTAssertEqual(observed[0].host, "203.0.113.5")
        XCTAssertEqual(observed[0].port, 51_000)
        XCTAssertEqual(observed[1].host, "example.org")
        XCTAssertEqual(observed[1].port, 8080)
    }

    /// Ansluter till en lokal SOCKS5-proxy, förhandlar CONNECT mot
    /// `targetHost:targetPort`, skickar sedan lite data och verifierar att
    /// den ekar tillbaka genom hela vägen (proxy -> SSH -> servern -> eko).
    private func connectViaSOCKS(proxyPort: Int, targetHost: String, targetPort: Int) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let collector = ByteCollectorHandler2()
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { channel in channel.pipeline.addHandler(collector) }
            .connect(host: "127.0.0.1", port: proxyPort)
            .get()

        var greeting = client.allocator.buffer(capacity: 3)
        greeting.writeBytes([0x05, 0x01, 0x00])
        try await client.writeAndFlush(greeting).get()
        try await waitForBytes(collector, count: 2)  // VER METHOD

        var request = client.allocator.buffer(capacity: 32)
        request.writeBytes([0x05, 0x01, 0x00, 0x03])
        request.writeInteger(UInt8(targetHost.utf8.count))
        request.writeString(targetHost)
        request.writeInteger(UInt16(targetPort))
        try await client.writeAndFlush(request).get()
        try await waitForBytes(collector, count: 2 + 10)  // greeting-svar + CONNECT-svar (10 byte)

        var payload = client.allocator.buffer(capacity: 8)
        payload.writeString("hallå")
        try await client.writeAndFlush(payload).get()

        var text = ""
        for _ in 0..<50 {
            text = await collector.text()
            if text.contains("hallå") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await client.close().get()
        try? await group.shutdownGracefully()
        XCTAssertTrue(text.contains("hallå"), "fick: \(text.debugDescription) (mål \(targetHost):\(targetPort))")
    }

    private func waitForBytes(_ collector: ByteCollectorHandler2, count: Int) async throws {
        for _ in 0..<50 {
            if await collector.text().utf8.count >= count { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
