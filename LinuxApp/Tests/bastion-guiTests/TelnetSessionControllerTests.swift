import XCTest
@testable import bastion_gui

/// `splitTrailingIncompleteUTF8` fick fel åt BÅDA hållen över tre
/// granskningsrundor på PR #181 (avkodade riktiga delade sekvenser för
/// tidigt, sedan höll kvar lösryckta fortsättningsbyte i evighet) — riktig
/// testtäckning istället för att bara resonera manuellt kring nästa fix.
final class TelnetSessionControllerTests: XCTestCase {
    private typealias Result = (complete: [UInt8], remainder: [UInt8])

    private func split(_ bytes: [UInt8]) -> Result {
        TelnetSessionController.splitTrailingIncompleteUTF8(bytes)
    }

    func testEmptyInputIsComplete() {
        let r = split([])
        XCTAssertEqual(r.complete, [])
        XCTAssertEqual(r.remainder, [])
    }

    func testPureASCIIIsAllComplete() {
        let bytes = Array("hello".utf8)
        let r = split(bytes)
        XCTAssertEqual(r.complete, bytes)
        XCTAssertEqual(r.remainder, [])
    }

    func testCompleteTwoByteScalarIsAllComplete() {
        // "é" = 0xC3 0xA9
        let bytes: [UInt8] = [0x68, 0x69, 0xC3, 0xA9]
        let r = split(bytes)
        XCTAssertEqual(r.complete, bytes)
        XCTAssertEqual(r.remainder, [])
    }

    func testFragmentedTwoByteScalarHoldsBackLeadAndContinuation() {
        // Chunk slutar med bara ledbyten för "é" (0xC3), fortsättningsbytet
        // (0xA9) kommer i nästa chunk.
        let bytes: [UInt8] = [0x68, 0x69, 0xC3]
        let r = split(bytes)
        XCTAssertEqual(r.complete, [0x68, 0x69])
        XCTAssertEqual(r.remainder, [0xC3])
    }

    func testFragmentedThreeByteScalarWithOneContinuationByte() {
        // "€" = 0xE2 0x82 0xAC — chunk har bara de två första byten.
        let bytes: [UInt8] = [0x41, 0xE2, 0x82]
        let r = split(bytes)
        XCTAssertEqual(r.complete, [0x41])
        XCTAssertEqual(r.remainder, [0xE2, 0x82])
    }

    func testCompleteThreeByteScalarIsAllComplete() {
        let bytes: [UInt8] = [0x41, 0xE2, 0x82, 0xAC]
        let r = split(bytes)
        XCTAssertEqual(r.complete, bytes)
        XCTAssertEqual(r.remainder, [])
    }

    func testFragmentedFourByteScalarJustTheLeadByte() {
        // 😀 = 0xF0 0x9F 0x98 0x80 — chunk slutar direkt efter ledbyten.
        let bytes: [UInt8] = [0x7A, 0xF0]
        let r = split(bytes)
        XCTAssertEqual(r.complete, [0x7A])
        XCTAssertEqual(r.remainder, [0xF0])
    }

    func testCompleteFourByteScalarIsAllComplete() {
        let bytes: [UInt8] = [0xF0, 0x9F, 0x98, 0x80]
        let r = split(bytes)
        XCTAssertEqual(r.complete, bytes)
        XCTAssertEqual(r.remainder, [])
    }

    /// Lösryckta fortsättningsbyte UTAN någon ledbyte inom räckhåll —
    /// trasig indata, ska INTE fastna i pendingBytes för alltid.
    func testStandaloneContinuationBytesWithNoLeadAreTreatedAsComplete() {
        let bytes: [UInt8] = [0x80, 0x81]
        let r = split(bytes)
        XCTAssertEqual(r.complete, bytes)
        XCTAssertEqual(r.remainder, [])
    }

    /// En ASCII-byte direkt efter en ofullständig sekvens (t.ex. servern
    /// blandar binärt skräp med text) — ledbyten hittas fortfarande, ASCII-
    /// byten före den är komplett.
    func testAsciiFollowedByFragmentedLead() {
        let bytes: [UInt8] = [0x61, 0x62, 0xE2, 0x82]
        let r = split(bytes)
        XCTAssertEqual(r.complete, [0x61, 0x62])
        XCTAssertEqual(r.remainder, [0xE2, 0x82])
    }
}
