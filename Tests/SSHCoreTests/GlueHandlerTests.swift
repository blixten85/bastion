import XCTest
import NIOCore
import NIOEmbedded
@testable import SSHCore

/// Fokuserade enhetstester för `GlueHandler` — komplement till
/// `PortForwardTests`s end-to-end-lyckad-väg-test (CodeRabbit-fynd på PR #25:
/// bara happy-path-eko var testat, inte half-close/felpropagering).
///
/// Backpressure (read()/pendingRead/partnerBecameWritable) testas INTE här:
/// `EmbeddedChannel` har ingen riktig socket-buffert, så att simulera
/// "kanalen är inte skrivbar" på ett meningsfullt sätt kräver en tyngre
/// integrationsrigg än vad ett `EmbeddedChannel`-baserat enhetstest ger —
/// bedömt som lägre värde än de två andra fallen (fel + half-close är de
/// mer sannolika regressionsvägarna i den här klassen).
final class GlueHandlerTests: XCTestCase {
    func testBridgesReadsAcrossMatchedPair() throws {
        let (a, b) = GlueHandler.matchedPair()
        let channelA = EmbeddedChannel(handler: a)
        let channelB = EmbeddedChannel(handler: b)
        defer {
            _ = try? channelA.finish()
            _ = try? channelB.finish()
        }

        var buf = channelA.allocator.buffer(capacity: 8)
        buf.writeString("hej")
        try channelA.writeInbound(buf)

        // A:s channelRead skriver på B (partner), inte tillbaka på A.
        XCTAssertNil(try channelA.readOutbound(as: ByteBuffer.self))
        let onB: ByteBuffer? = try channelB.readOutbound(as: ByteBuffer.self)
        XCTAssertEqual(onB.map { String(buffer: $0) }, "hej")
    }

    func testHalfCloseOnOnePartnerClosesTheOther() throws {
        let (a, b) = GlueHandler.matchedPair()
        let channelA = EmbeddedChannel(handler: a)
        let channelB = EmbeddedChannel(handler: b)
        defer {
            _ = try? channelA.finish()
            _ = try? channelB.finish()
        }

        // A läser EOF (fjärrsidan stängde sin skrivriktning). Varken
        // PortForward.swift eller GlueHandler sätter allowRemoteHalfClosure,
        // så NIOs standardbeteende stänger hela A-kanalen (inte bara läs-
        // riktningen) — verifierat empiriskt, inte antaget: ett tidigare
        // försök som antog att A förblev aktiv (bara B:s utgång stängdes)
        // föll på just den punkten. GlueHandlers egen logik (partnerWriteEOF)
        // stänger dessutom B:s utgående sida explicit.
        channelA.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        XCTAssertFalse(channelA.isActive, "NIOs standard (utan allowRemoteHalfClosure) stänger hela A vid inputClosed")
        XCTAssertFalse(channelB.isActive, "B:s utgående sida ska ha stängts av A:s half-close (GlueHandler.partnerWriteEOF)")
    }

    func testErrorOnOnePartnerFullyClosesTheOther() throws {
        let (a, b) = GlueHandler.matchedPair()
        let channelA = EmbeddedChannel(handler: a)
        let channelB = EmbeddedChannel(handler: b)
        defer {
            _ = try? channelA.finish()
            _ = try? channelB.finish()
        }

        channelA.pipeline.fireErrorCaught(SSHError.channelFailed("test-fel"))

        XCTAssertFalse(channelB.isActive, "B ska stängas helt när A:s errorCaught triggas")
    }
}
