import XCTest
import NIOCore
import NIOPosix
@testable import SSHCore

final class TelnetIACFilterTests: XCTestCase {
    func testPlainDataPassesThroughUnchanged() {
        let filter = TelnetIACFilter()
        let (data, replies) = filter.process(Array("hello\r\n".utf8))
        XCTAssertEqual(data, Array("hello\r\n".utf8))
        XCTAssertTrue(replies.isEmpty)
    }

    func testEscapedIACByteIsPreservedAsLiteral0xFF() {
        let filter = TelnetIACFilter()
        let (data, replies) = filter.process([0x41, 255, 255, 0x42])
        XCTAssertEqual(data, [0x41, 255, 0x42])
        XCTAssertTrue(replies.isEmpty)
    }

    /// Servern erbjuder ett alternativ (WILL echo) — klienten ska refusera
    /// (DONT) istället för att implementera echo-optionen.
    func testWillIsRefusedWithDont() {
        let filter = TelnetIACFilter()
        let (data, replies) = filter.process([255, 251, 1]) // IAC WILL ECHO
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(replies, [255, 254, 1]) // IAC DONT ECHO
    }

    /// Servern begär att KLIENTEN aktiverar ett alternativ (DO) — refuseras
    /// med WONT.
    func testDoIsRefusedWithWont() {
        let filter = TelnetIACFilter()
        let (data, replies) = filter.process([255, 253, 24]) // IAC DO TERMINAL-TYPE
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(replies, [255, 252, 24]) // IAC WONT TERMINAL-TYPE
    }

    /// WONT/DONT är redan negativa svar — inget eget svar krävs.
    func testWontAndDontRequireNoReply() {
        let filter = TelnetIACFilter()
        let (data, replies) = filter.process([255, 252, 1, 255, 254, 24])
        XCTAssertTrue(data.isEmpty)
        XCTAssertTrue(replies.isEmpty)
    }

    /// Subförhandling (SB...SE) kastas bort helt — vi förhandlar inga
    /// alternativ, så det finns inget giltigt svar att extrahera ur den.
    func testSubnegotiationIsDiscarded() {
        let filter = TelnetIACFilter()
        let sb: [UInt8] = [255, 250, 24, 0, 0x78, 0x74, 0x65, 0x72, 0x6d, 255, 240] // IAC SB TERMINAL-TYPE IS "xterm" IAC SE
        let (data, replies) = filter.process(sb + Array("ok".utf8))
        XCTAssertEqual(data, Array("ok".utf8))
        XCTAssertTrue(replies.isEmpty)
    }

    /// Kommandon utan optionsbyte (t.ex. NOP) ska bara konsumeras, inte
    /// läcka in i databufferten eller tolkas som ett optionsbyte.
    func testCommandWithoutOptionByteIsConsumed() {
        let filter = TelnetIACFilter()
        let (data, replies) = filter.process([255, 241] + Array("x".utf8)) // IAC NOP, sen "x"
        XCTAssertEqual(data, Array("x".utf8))
        XCTAssertTrue(replies.isEmpty)
    }

    /// En IAC-sekvens fragmenterad över flera `process`-anrop (motsvarar
    /// flera TCP-läsningar) måste hanteras korrekt — staten får inte
    /// glömmas mellan anropen.
    func testNegotiationFragmentedAcrossMultipleReads() {
        let filter = TelnetIACFilter()
        let (data1, replies1) = filter.process([255])
        XCTAssertTrue(data1.isEmpty)
        XCTAssertTrue(replies1.isEmpty)
        let (data2, replies2) = filter.process([251])
        XCTAssertTrue(data2.isEmpty)
        XCTAssertTrue(replies2.isEmpty)
        let (data3, replies3) = filter.process([1])
        XCTAssertTrue(data3.isEmpty)
        XCTAssertEqual(replies3, [255, 254, 1])
    }
}

final class TelnetSessionTests: XCTestCase {
    /// End-to-end mot en RIKTIG TCP-server som beter sig som en telnet-
    /// server: skickar en förhandling (WILL ECHO) klienten ska refusera,
    /// sen ett kommando klienten ska eka tillbaka rensat, och läser sedan
    /// klientens svar direkt av tråden — bevisar att hela vägen (NIO-
    /// kanalen, IAC-filtret, AsyncThrowingStream) fungerar ihop, inte bara
    /// filtrets logik i isolering.
    func testConnectStripsNegotiationAndDeliversCleanData() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let serverReceivedNegotiationReply = group.next().makePromise(of: [UInt8].self)

        final class FakeTelnetServer: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer
            let receivedPromise: EventLoopPromise<[UInt8]>
            init(receivedPromise: EventLoopPromise<[UInt8]>) { self.receivedPromise = receivedPromise }

            func channelActive(context: ChannelHandlerContext) {
                // IAC WILL ECHO, sen lite text servern "säger".
                var buf = context.channel.allocator.buffer(capacity: 16)
                buf.writeBytes([255, 251, 1])
                buf.writeString("welcome\r\n")
                context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buf = unwrapInboundIn(data)
                let bytes = buf.readBytes(length: buf.readableBytes) ?? []
                receivedPromise.succeed(bytes)
            }
        }

        let listener = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(FakeTelnetServer(receivedPromise: serverReceivedNegotiationReply))
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { Task { try? await listener.close() } }

        guard let port = listener.localAddress?.port else {
            return XCTFail("servern fick ingen port")
        }

        let session = try await TelnetSession.connect(target: TelnetTarget(host: "127.0.0.1", port: port))
        defer { Task { await session.close() } }

        var iterator = session.output.makeAsyncIterator()
        let firstChunk = try await iterator.next()
        XCTAssertEqual(firstChunk, Array("welcome\r\n".utf8), "servens förhandling ska vara borttagen, bara texten kvar")

        // Beviset på att klientens svar faktiskt gick tillbaka på tråden,
        // inte bara producerades internt i filtret.
        let reply = try await serverReceivedNegotiationReply.futureResult.get()
        XCTAssertEqual(reply, [255, 254, 1]) // IAC DONT ECHO
    }
}
