import XCTest
import NIOCore
@testable import SSHCore

final class SFTPProtocolTests: XCTestCase {
    // MARK: - Sträng/bytes-kodning

    func testStringRoundTrip() throws {
        var buf = ByteBuffer()
        buf.writeSFTPString("/home/user/åäö.txt")
        let decoded = try buf.readSFTPString()
        XCTAssertEqual(decoded, "/home/user/åäö.txt")
        XCTAssertEqual(buf.readableBytes, 0)
    }

    func testEmptyStringRoundTrip() throws {
        var buf = ByteBuffer()
        buf.writeSFTPString("")
        XCTAssertEqual(try buf.readSFTPString(), "")
    }

    func testBytesRoundTrip() throws {
        var buf = ByteBuffer()
        buf.writeSFTPBytes([0x00, 0xFF, 0x10, 0x01])
        XCTAssertEqual(try buf.readSFTPBytes(), [0x00, 0xFF, 0x10, 0x01])
    }

    func testTruncatedStringThrowsInsteadOfCrashing() {
        var buf = ByteBuffer()
        buf.writeInteger(UInt32(100))  // påstår 100 byte, men skriver inga
        XCTAssertThrowsError(try buf.readSFTPString()) {
            XCTAssertEqual($0 as? SFTPProtocolError, .truncatedMessage)
        }
    }

    // MARK: - Attribut

    func testAttributesRoundTripAllFieldsSet() throws {
        let original = SFTPFileAttributes(
            size: 12345, uid: 1000, gid: 1000, permissions: 0o644,
            accessTime: 1_720_000_000, modificationTime: 1_720_000_100
        )
        var buf = ByteBuffer()
        original.encode(into: &buf)
        let decoded = try SFTPFileAttributes.decode(from: &buf)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(buf.readableBytes, 0)
    }

    func testAttributesRoundTripNoFieldsSet() throws {
        let original = SFTPFileAttributes()
        var buf = ByteBuffer()
        original.encode(into: &buf)
        // Bara flaggfältet (4 byte, allt noll) ska skrivas.
        XCTAssertEqual(buf.readableBytes, 4)
        let decoded = try SFTPFileAttributes.decode(from: &buf)
        XCTAssertEqual(decoded, original)
    }

    func testAttributesRoundTripOnlySizeSet() throws {
        let original = SFTPFileAttributes(size: 42)
        var buf = ByteBuffer()
        original.encode(into: &buf)
        let decoded = try SFTPFileAttributes.decode(from: &buf)
        XCTAssertEqual(decoded.size, 42)
        XCTAssertNil(decoded.uid)
        XCTAssertNil(decoded.permissions)
    }

    func testAttributesRoundTripOnlyUidGidPairSet() throws {
        // Regressionstest för CodeRabbit-fyndet (PR #37): uid/gid är ett par
        // i v3-trådformatet. Tidigare kunde koden skriva en falsk 0:a för
        // den andra hälften om bara en var satt — det är nu en
        // precondition-krasch istället (testas inte här, går inte fånga
        // ett precondition-trap i XCTest utan att krascha hela sviten) —
        // det som verifieras här är att det giltiga, ihopparade fallet
        // fortfarande round-trippar korrekt utan accessTime/modificationTime.
        let original = SFTPFileAttributes(uid: 1000, gid: 1000)
        var buf = ByteBuffer()
        original.encode(into: &buf)
        let decoded = try SFTPFileAttributes.decode(from: &buf)
        XCTAssertEqual(decoded.uid, 1000)
        XCTAssertEqual(decoded.gid, 1000)
        XCTAssertNil(decoded.accessTime)
        XCTAssertNil(decoded.modificationTime)
    }

    func testIsDirectoryReadsPOSIXTypeBits() {
        XCTAssertTrue(SFTPFileAttributes(permissions: 0o040755).isDirectory)
        XCTAssertFalse(SFTPFileAttributes(permissions: 0o100644).isDirectory)
        XCTAssertFalse(SFTPFileAttributes(permissions: nil).isDirectory)
    }

    func testIsSymbolicLinkReadsPOSIXTypeBits() {
        XCTAssertTrue(SFTPFileAttributes(permissions: 0o120777).isSymbolicLink)
        XCTAssertFalse(SFTPFileAttributes(permissions: 0o040755).isSymbolicLink)
    }

    // MARK: - Request-kodning (byte-exakt mot spec, SSH_FXP_* enligt draft-ietf-secsh-filexfer-02 §3)

    func testInitMessageWireFormat() {
        var packet = SFTPRequest.initMessage(version: 3)
        // uint32 längd (5 = 1 typbyte + 4 versionsbyte) + typbyte (1) + uint32 version
        XCTAssertEqual(packet.readInteger(as: UInt32.self), 5)
        XCTAssertEqual(packet.readInteger(as: UInt8.self), SFTPMessageType.initMsg.rawValue)
        XCTAssertEqual(packet.readInteger(as: UInt32.self), 3)
        XCTAssertEqual(packet.readableBytes, 0)
    }

    func testRealpathWireFormat() throws {
        var packet = SFTPRequest.realpath(id: 7, path: "/tmp")
        let length: UInt32! = packet.readInteger()
        let type: UInt8! = packet.readInteger()
        XCTAssertEqual(type, SFTPMessageType.realpath.rawValue)
        let id: UInt32! = packet.readInteger()
        XCTAssertEqual(id, 7)
        XCTAssertEqual(try packet.readSFTPString(), "/tmp")
        XCTAssertEqual(packet.readableBytes, 0)
        // längden ska stämma med vad som faktiskt skrevs (typbyte + id + sträng)
        XCTAssertEqual(Int(length), 1 + 4 + 4 + 4)  // typ + id + strlen-prefix + "/tmp"
    }

    func testOpenWireFormatIncludesFlagsAndAttrs() throws {
        var packet = SFTPRequest.open(id: 1, path: "x", flags: [.read, .write], attributes: SFTPFileAttributes(size: 10))
        _ = packet.readInteger(as: UInt32.self)  // längd
        XCTAssertEqual(packet.readInteger(as: UInt8.self), SFTPMessageType.open.rawValue)
        XCTAssertEqual(packet.readInteger(as: UInt32.self), 1)  // id
        XCTAssertEqual(try packet.readSFTPString(), "x")
        XCTAssertEqual(packet.readInteger(as: UInt32.self), SFTPOpenFlags.read.union(.write).rawValue)
        let attrs = try SFTPFileAttributes.decode(from: &packet)
        XCTAssertEqual(attrs.size, 10)
    }

    func testCloseWireFormat() throws {
        var packet = SFTPRequest.close(id: 2, handle: [1, 2, 3])
        _ = packet.readInteger(as: UInt32.self)
        XCTAssertEqual(packet.readInteger(as: UInt8.self), SFTPMessageType.close.rawValue)
        XCTAssertEqual(packet.readInteger(as: UInt32.self), 2)
        XCTAssertEqual(try packet.readSFTPBytes(), [1, 2, 3])
    }

    // MARK: - Response-avkodning

    func testDecodeVersion() throws {
        var payload = ByteBuffer()
        payload.writeInteger(UInt32(3))
        let response = try SFTPResponse.decode(type: .version, from: &payload)
        XCTAssertEqual(response, .version(3))
    }

    func testDecodeStatusOK() throws {
        var payload = ByteBuffer()
        payload.writeInteger(UInt32(42))  // id
        payload.writeInteger(SFTPStatusCode.ok.rawValue)
        payload.writeSFTPString("")
        payload.writeSFTPString("")  // language tag
        let response = try SFTPResponse.decode(type: .status, from: &payload)
        XCTAssertEqual(response, .status(id: 42, code: .ok, message: ""))
    }

    func testDecodeStatusNoSuchFile() throws {
        var payload = ByteBuffer()
        payload.writeInteger(UInt32(1))
        payload.writeInteger(SFTPStatusCode.noSuchFile.rawValue)
        payload.writeSFTPString("No such file")
        payload.writeSFTPString("en")
        let response = try SFTPResponse.decode(type: .status, from: &payload)
        guard case .status(let id, let code, let message) = response else {
            return XCTFail("fel gren")
        }
        XCTAssertEqual(id, 1)
        XCTAssertEqual(code, .noSuchFile)
        XCTAssertEqual(message, "No such file")
    }

    func testDecodeUnknownStatusCodeDoesNotCrash() throws {
        var payload = ByteBuffer()
        payload.writeInteger(UInt32(1))
        payload.writeInteger(UInt32(999))  // okänd kod, inte i SSH_FX_*-listan
        payload.writeSFTPString("")
        payload.writeSFTPString("")
        let response = try SFTPResponse.decode(type: .status, from: &payload)
        guard case .status(_, let code, _) = response else { return XCTFail("fel gren") }
        XCTAssertEqual(code, .unknown(999))
    }

    func testDecodeStatusConsumesLanguageTag() throws {
        // Regressionstest för CodeRabbit-fyndet (PR #37): en tidigare
        // implementation läste bara meddelandesträngen (med try?, som
        // dessutom dolde trunkeringsfel) och lämnade v3:s language-tag
        // oläst i bufferten.
        var payload = ByteBuffer()
        payload.writeInteger(UInt32(1))
        payload.writeInteger(SFTPStatusCode.ok.rawValue)
        payload.writeSFTPString("meddelande")
        payload.writeSFTPString("en-US")
        let response = try SFTPResponse.decode(type: .status, from: &payload)
        guard case .status(_, _, let message) = response else { return XCTFail("fel gren") }
        XCTAssertEqual(message, "meddelande")
        XCTAssertEqual(payload.readableBytes, 0)
    }

    func testDecodeStatusThrowsOnTruncatedMessage() throws {
        // try? dolde tidigare trunkerade STATUS-meddelanden bakom en tom
        // sträng — ett skadat/kortslutet paket ska kastas, inte tolkas som
        // "inget meddelande" (CodeRabbit-fynd, PR #37).
        var payload = ByteBuffer()
        payload.writeInteger(UInt32(1))
        payload.writeInteger(SFTPStatusCode.ok.rawValue)
        payload.writeInteger(UInt32(50))  // säger 50 byte sträng men skickar inga
        XCTAssertThrowsError(try SFTPResponse.decode(type: .status, from: &payload))
    }

    func testDecodeHandle() throws {
        var payload = ByteBuffer()
        payload.writeInteger(UInt32(5))
        payload.writeSFTPBytes([0xAA, 0xBB])
        let response = try SFTPResponse.decode(type: .handle, from: &payload)
        XCTAssertEqual(response, .handle(id: 5, handle: [0xAA, 0xBB]))
    }

    func testDecodeData() throws {
        var payload = ByteBuffer()
        payload.writeInteger(UInt32(6))
        payload.writeSFTPBytes(Array("hej".utf8))
        let response = try SFTPResponse.decode(type: .data, from: &payload)
        XCTAssertEqual(response, .data(id: 6, bytes: Array("hej".utf8)))
    }

    func testDecodeNameWithMultipleEntries() throws {
        var payload = ByteBuffer()
        payload.writeInteger(UInt32(9))  // id
        payload.writeInteger(UInt32(2))  // count
        payload.writeSFTPString(".")
        payload.writeSFTPString("drwxr-xr-x . .")
        SFTPFileAttributes(permissions: 0o755).encode(into: &payload)
        payload.writeSFTPString("file.txt")
        payload.writeSFTPString("-rw-r--r-- . .")
        SFTPFileAttributes(size: 100, permissions: 0o644).encode(into: &payload)

        let response = try SFTPResponse.decode(type: .name, from: &payload)
        guard case .name(let id, let entries) = response else { return XCTFail("fel gren") }
        XCTAssertEqual(id, 9)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].filename, ".")
        XCTAssertEqual(entries[0].attributes.permissions, 0o755)
        XCTAssertEqual(entries[1].filename, "file.txt")
        XCTAssertEqual(entries[1].attributes.size, 100)
        XCTAssertEqual(payload.readableBytes, 0)
    }

    func testDecodeNameRejectsImpossiblyLargeCount() throws {
        // Regressionstest för CodeRabbit-fyndet (PR #37): count är obetrodd
        // tråddata. reserveCapacity(Int(count)) skulle tidigare försöka
        // allokera för en miljon poster fastän bufferten bara innehåller
        // några byte — nu ska paketet kastas som trunkerat istället.
        var payload = ByteBuffer()
        payload.writeInteger(UInt32(1))  // id
        payload.writeInteger(UInt32(1_000_000))  // count, långt fler än vad bufferten kan rymma
        payload.writeSFTPString(".")  // bara en enda liten post faktiskt skickad
        XCTAssertThrowsError(try SFTPResponse.decode(type: .name, from: &payload))
    }

    func testDecodeAttrs() throws {
        var payload = ByteBuffer()
        payload.writeInteger(UInt32(3))
        SFTPFileAttributes(size: 55).encode(into: &payload)
        let response = try SFTPResponse.decode(type: .attrs, from: &payload)
        XCTAssertEqual(response, .attrs(id: 3, attributes: SFTPFileAttributes(size: 55)))
    }

    func testDecodeRequestTypeAsResponseThrows() {
        var payload = ByteBuffer()
        payload.writeInteger(UInt32(1))
        XCTAssertThrowsError(try SFTPResponse.decode(type: .open, from: &payload)) {
            XCTAssertEqual($0 as? SFTPProtocolError, .unexpectedMessageType(SFTPMessageType.open.rawValue))
        }
    }
}
