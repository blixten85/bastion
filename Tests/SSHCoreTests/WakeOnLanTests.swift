import XCTest
import NIOCore
import NIOPosix
@testable import SSHCore

final class WakeOnLanTests: XCTestCase {
    func testParseMACWithColons() throws {
        XCTAssertEqual(try WakeOnLan.parseMAC("AA:BB:CC:DD:EE:FF"), [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    }

    func testParseMACWithDashes() throws {
        XCTAssertEqual(try WakeOnLan.parseMAC("aa-bb-cc-dd-ee-ff"), [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    }

    func testParseMACWithoutSeparators() throws {
        XCTAssertEqual(try WakeOnLan.parseMAC("aabbccddeeff"), [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    }

    func testParseMACRejectsWrongLength() {
        XCTAssertThrowsError(try WakeOnLan.parseMAC("AA:BB:CC:DD:EE")) { error in
            XCTAssertEqual(error as? WakeOnLanError, .invalidMACAddress("AA:BB:CC:DD:EE"))
        }
    }

    func testParseMACRejectsNonHexCharacters() {
        XCTAssertThrowsError(try WakeOnLan.parseMAC("ZZ:BB:CC:DD:EE:FF"))
    }

    /// Plattformens sockets-lager tolkar annars ofta ett portnummer utanför
    /// giltigt intervall modulo 65536 (t.ex. 70000 -> 4464) istället för att
    /// kasta — paketet skulle tyst gå till FEL port. Måste valideras explicit.
    func testSendRejectsOutOfRangePort() async throws {
        do {
            try await WakeOnLan.send(mac: "AA:BB:CC:DD:EE:FF", port: 70_000)
            XCTFail("skulle ha kastat .invalidPort")
        } catch let error as WakeOnLanError {
            XCTAssertEqual(error, .invalidPort(70_000))
        }
    }

    func testSendRejectsZeroPort() async throws {
        do {
            try await WakeOnLan.send(mac: "AA:BB:CC:DD:EE:FF", port: 0)
            XCTFail("skulle ha kastat .invalidPort")
        } catch let error as WakeOnLanError {
            XCTAssertEqual(error, .invalidPort(0))
        }
    }

    /// 6 bytes 0xFF följt av MAC-adressen upprepad exakt 16 gånger — det
    /// dokumenterade formatet, inte bara "något som råkar fungera".
    func testMagicPacketFormat() throws {
        let packet = try WakeOnLan.magicPacket(for: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet[0..<6]), [UInt8](repeating: 0xFF, count: 6))
        let mac: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        for i in 0..<16 {
            let start = 6 + i * 6
            XCTAssertEqual(Array(packet[start..<(start + 6)]), mac, "repetition \(i)")
        }
    }

    /// End-to-end mot en RIKTIG UDP-lyssnare på loopback — bevisar att
    /// paketet faktiskt går ut på tråden med rätt innehåll, inte bara att
    /// byte-layouten stämmer i minnet.
    func testSendDeliversMagicPacketOverRealUDP() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        final class Receiver: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = AddressedEnvelope<ByteBuffer>
            let promise: EventLoopPromise<[UInt8]>
            init(promise: EventLoopPromise<[UInt8]>) { self.promise = promise }
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let envelope = unwrapInboundIn(data)
                var buf = envelope.data
                promise.succeed(buf.readBytes(length: buf.readableBytes) ?? [])
            }
        }

        let receivedPromise = group.next().makePromise(of: [UInt8].self)
        let listener = try await DatagramBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(Receiver(promise: receivedPromise))
            }
            .bind(host: "127.0.0.1", port: 0).get()

        // Städar lyssnaren/gruppen oavsett hur resten av testet lämnas (fel i
        // WakeOnLan.send eller i futureResult.get() hade annars läckt dem —
        // cubic-fynd, PR #173).
        do {
            guard let port = listener.localAddress?.port else {
                XCTFail("lyssnaren fick ingen port")
                try await listener.close()
                try await group.shutdownGracefully()
                return
            }

            try await WakeOnLan.send(mac: "AA:BB:CC:DD:EE:FF", broadcastAddress: "127.0.0.1", port: port)

            let received = try await receivedPromise.futureResult.get()
            try await listener.close()
            try await group.shutdownGracefully()
            XCTAssertEqual(received, try WakeOnLan.magicPacket(for: "AA:BB:CC:DD:EE:FF"))
        } catch {
            try? await listener.close()
            try? await group.shutdownGracefully()
            throw error
        }
    }
}
