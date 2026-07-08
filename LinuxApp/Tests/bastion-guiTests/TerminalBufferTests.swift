import XCTest
import SwiftCrossUI
@testable import bastion_gui

/// `TerminalBuffer` hade INGEN testtäckning innan den här filen (upptäckt
/// 2026-07-08 — en tidigare sammanfattning påstod felaktigt 17 testfall för
/// den, verifierat inte sant; README:ts "testad, se nedan"-rad pekade på
/// ingenting). Färgmatematiken för SGR 256-color/True Color verifierades
/// tidigare bara manuellt mot xterm-referensvärden — de referensvärdena
/// (196=röd, 46=grön, 21=blå, 232/255=gråskale-ändpunkter) är kodade som
/// riktiga assertions här istället.
@MainActor
final class TerminalBufferTests: XCTestCase {
    // MARK: - Grundläggande skrivning + markörflytt

    func testWriteAdvancesCursor() {
        let buf = TerminalBuffer(cols: 10, rows: 3)
        buf.feed("Hi")
        XCTAssertEqual(buf.cursorCol, 2)
        XCTAssertEqual(buf.cursorRow, 0)
        XCTAssertEqual(buf.rows[0][0].char, "H")
        XCTAssertEqual(buf.rows[0][1].char, "i")
    }

    func testLineWrapAtColumnEdge() {
        let buf = TerminalBuffer(cols: 3, rows: 3)
        buf.feed("abcd")
        // "abc" fyller rad 0, "d" radbryter till rad 1 kol 0.
        XCTAssertEqual(String(buf.rows[0].map(\.char)), "abc")
        XCTAssertEqual(buf.rows[1][0].char, "d")
        XCTAssertEqual(buf.cursorRow, 1)
        XCTAssertEqual(buf.cursorCol, 1)
    }

    func testCarriageReturnResetsColumnOnly() {
        let buf = TerminalBuffer(cols: 10, rows: 3)
        buf.feed("abc\rXY")
        XCTAssertEqual(buf.cursorRow, 0)
        // "abc" skrivs, \r nollställer bara kolumnen (inte raden), "XY"
        // skriver över "ab" — "c" står kvar orört.
        XCTAssertEqual(buf.rows[0][0].char, "X")
        XCTAssertEqual(buf.rows[0][1].char, "Y")
        XCTAssertEqual(buf.rows[0][2].char, "c")
        XCTAssertEqual(buf.rows[0][3].char, " ")
    }

    func testNewlineAdvancesRowWithoutResettingColumn() {
        let buf = TerminalBuffer(cols: 10, rows: 3)
        buf.feed("ab\n")
        XCTAssertEqual(buf.cursorRow, 1)
        XCTAssertEqual(buf.cursorCol, 2)
    }

    func testCRLFTogetherActLikeRealNewline() {
        let buf = TerminalBuffer(cols: 10, rows: 3)
        buf.feed("ab\r\ncd")
        XCTAssertEqual(buf.cursorRow, 1)
        XCTAssertEqual(buf.rows[1][0].char, "c")
        XCTAssertEqual(buf.rows[1][1].char, "d")
    }

    func testBackspaceMovesCursorLeftWithoutErasing() {
        let buf = TerminalBuffer(cols: 10, rows: 3)
        buf.feed("abc\u{08}")
        XCTAssertEqual(buf.cursorCol, 2)
        // Ingen radering — bara markörflytt, tecknet "c" står kvar.
        XCTAssertEqual(buf.rows[0][2].char, "c")
    }

    func testBackspaceAtColumnZeroClampsInsteadOfGoingNegative() {
        let buf = TerminalBuffer(cols: 10, rows: 3)
        buf.feed("\u{08}\u{08}")
        XCTAssertEqual(buf.cursorCol, 0)
    }

    func testTabAdvancesToNextStopOfEight() {
        let buf = TerminalBuffer(cols: 40, rows: 3)
        buf.feed("ab\t")
        XCTAssertEqual(buf.cursorCol, 8)
        buf.feed("\t")
        XCTAssertEqual(buf.cursorCol, 16)
    }

    func testTabClampsToLastColumn() {
        let buf = TerminalBuffer(cols: 5, rows: 3)
        buf.feed("\t")
        XCTAssertEqual(buf.cursorCol, 4)
    }

    func testUnknownLowControlCharactersAreIgnoredNotWritten() {
        let buf = TerminalBuffer(cols: 10, rows: 3)
        buf.feed("a\u{07}b") // BEL mellan två tecken
        XCTAssertEqual(buf.cursorCol, 2)
        XCTAssertEqual(buf.rows[0][0].char, "a")
        XCTAssertEqual(buf.rows[0][1].char, "b")
    }

    // MARK: - Scrollning när skärmen är full

    func testWritingPastLastRowScrollsBufferUp() {
        let buf = TerminalBuffer(cols: 5, rows: 2)
        // \r\n, inte bara \n — matchar vad en riktig SSH-PTY faktiskt
        // skickar (termios ONLCR översätter utgående \n till \r\n som
        // standard). Ren \n lämnar cursorCol OFÖRÄNDRAD (korrekt VT100-
        // beteende — \n flyttar bara raden, inte kolumnen), vilket när
        // markören redan står i "väntande radbrytning"-läge (cursorCol
        // == cols efter att exakt ha fyllt en rad) ger en extra oavsiktlig
        // scroll vid nästa tecken — ett smalt men verkligt hörnfall,
        // dokumenterat i ROADMAP.md istället för att ändras här.
        buf.feed("11111\r\n22222\r\n33333")
        XCTAssertEqual(String(buf.rows[0].map(\.char)), "22222")
        XCTAssertEqual(String(buf.rows[1].map(\.char)), "33333")
        XCTAssertEqual(buf.cursorRow, 1)
    }

    // MARK: - Markörflytt (CSI A/B/C/D/H/f)

    func testCursorUpDownLeftRightClampToBounds() {
        let buf = TerminalBuffer(cols: 10, rows: 5)
        buf.feed("\u{1B}[3B") // ner 3
        XCTAssertEqual(buf.cursorRow, 3)
        buf.feed("\u{1B}[10B") // ner 10 -> clampad till sista raden
        XCTAssertEqual(buf.cursorRow, 4)
        buf.feed("\u{1B}[2A") // upp 2
        XCTAssertEqual(buf.cursorRow, 2)
        buf.feed("\u{1B}[5C") // höger 5
        XCTAssertEqual(buf.cursorCol, 5)
        buf.feed("\u{1B}[2D") // vänster 2
        XCTAssertEqual(buf.cursorCol, 3)
        buf.feed("\u{1B}[100D") // vänster 100 -> clampad till 0
        XCTAssertEqual(buf.cursorCol, 0)
    }

    func testCursorMovementWithoutExplicitCountDefaultsToOne() {
        let buf = TerminalBuffer(cols: 10, rows: 5)
        buf.feed("\u{1B}[B") // CSI B utan parameter = 1
        XCTAssertEqual(buf.cursorRow, 1)
    }

    func testCursorPositionCSIHSetsRowAndColumnOneIndexed() {
        let buf = TerminalBuffer(cols: 10, rows: 5)
        buf.feed("\u{1B}[3;5H")
        XCTAssertEqual(buf.cursorRow, 2) // 1-indexerat -> 0-indexerat
        XCTAssertEqual(buf.cursorCol, 4)
    }

    func testCursorPositionWithNoParamsGoesToOrigin() {
        let buf = TerminalBuffer(cols: 10, rows: 5)
        buf.feed("\u{1B}[3;5H\u{1B}[H")
        XCTAssertEqual(buf.cursorRow, 0)
        XCTAssertEqual(buf.cursorCol, 0)
    }

    // MARK: - Radering (CSI J/K)

    func testEraseLineDefaultModeClearsFromCursorToEnd() {
        let buf = TerminalBuffer(cols: 5, rows: 2)
        buf.feed("abcde\u{1B}[3D\u{1B}[K") // markör på kol 2, radera framåt
        XCTAssertEqual(String(buf.rows[0].map(\.char)), "ab   ")
    }

    func testEraseLineMode1ClearsFromStartToCursorInclusive() {
        let buf = TerminalBuffer(cols: 5, rows: 2)
        buf.feed("abcde\u{1B}[3D\u{1B}[1K") // markör på kol 2, radera bakåt inklusive
        XCTAssertEqual(String(buf.rows[0].map(\.char)), "   de")
    }

    func testEraseLineMode2ClearsWholeLine() {
        let buf = TerminalBuffer(cols: 5, rows: 2)
        buf.feed("abcde\u{1B}[2K")
        XCTAssertEqual(String(buf.rows[0].map(\.char)), "     ")
    }

    func testEraseDisplayMode2ClearsEverything() {
        let buf = TerminalBuffer(cols: 3, rows: 2)
        buf.feed("abc\r\ndef\u{1B}[2J")
        XCTAssertEqual(String(buf.rows[0].map(\.char)), "   ")
        XCTAssertEqual(String(buf.rows[1].map(\.char)), "   ")
    }

    func testEraseDisplayDefaultModeClearsFromCursorToEndOfScreen() {
        let buf = TerminalBuffer(cols: 3, rows: 2)
        buf.feed("abc\r\ndef\u{1B}[H\u{1B}[1C\u{1B}[J") // markör rad0 kol1, radera framåt+neråt
        XCTAssertEqual(String(buf.rows[0].map(\.char)), "a  ")
        XCTAssertEqual(String(buf.rows[1].map(\.char)), "   ")
    }

    // MARK: - SGR: grundfärger + bold

    func testStandardForegroundColorApplied() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[31mX")
        XCTAssertEqual(buf.rows[0][0].fg, Color(red: 0.75, green: 0.15, blue: 0.15))
    }

    func testBrightForegroundColorApplied() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[91mX")
        XCTAssertEqual(buf.rows[0][0].fg, Color(red: 1.00, green: 0.35, blue: 0.35))
    }

    func testBackgroundColorApplied() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[44mX")
        XCTAssertEqual(buf.rows[0][0].bg, Color(red: 0.20, green: 0.35, blue: 0.85))
    }

    func testBoldToggle() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[1mX\u{1B}[22mY")
        XCTAssertTrue(buf.rows[0][0].bold)
        XCTAssertFalse(buf.rows[0][1].bold)
    }

    func testSGRResetClearsColorsAndBold() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[1;31;44mX\u{1B}[0mY")
        XCTAssertNotNil(buf.rows[0][0].fg)
        XCTAssertNil(buf.rows[0][1].fg)
        XCTAssertNil(buf.rows[0][1].bg)
        XCTAssertFalse(buf.rows[0][1].bold)
    }

    func testDefaultForegroundAndBackgroundResetIndividually() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[31;44mX\u{1B}[39mY\u{1B}[49mZ")
        XCTAssertNotNil(buf.rows[0][0].fg)
        XCTAssertNotNil(buf.rows[0][0].bg)
        XCTAssertNil(buf.rows[0][1].fg)   // 39 = default fg
        XCTAssertNotNil(buf.rows[0][1].bg) // bg opåverkad
        XCTAssertNil(buf.rows[0][2].bg)   // 49 = default bg
    }

    // MARK: - SGR: 256-färg (38;5;n / 48;5;n) — xterm-referensvärden

    func testColor256StandardRangeMatchesAnsiPalette() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[38;5;1mX") // n=1 -> samma som SGR 31
        XCTAssertEqual(buf.rows[0][0].fg, Color(red: 0.75, green: 0.15, blue: 0.15))
    }

    func testColor256Value196IsPureRed() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[38;5;196mX")
        XCTAssertEqual(buf.rows[0][0].fg, Color(red: 1.0, green: 0.0, blue: 0.0))
    }

    func testColor256Value46IsPureGreen() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[38;5;46mX")
        XCTAssertEqual(buf.rows[0][0].fg, Color(red: 0.0, green: 1.0, blue: 0.0))
    }

    func testColor256Value21IsPureBlue() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[38;5;21mX")
        XCTAssertEqual(buf.rows[0][0].fg, Color(red: 0.0, green: 0.0, blue: 1.0))
    }

    func testColor256GrayscaleRampEndpoints() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[38;5;232mX")
        let low = buf.rows[0][0].fg
        buf.feed("\u{1B}[38;5;255mY")
        let high = buf.rows[0][1].fg
        XCTAssertEqual(low, Color(white: 8.0 / 255))
        XCTAssertEqual(high, Color(white: 238.0 / 255))
    }

    func testBackground256ColorAppliedIndependentlyOfForeground() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[48;5;46mX")
        XCTAssertEqual(buf.rows[0][0].bg, Color(red: 0.0, green: 1.0, blue: 0.0))
        XCTAssertNil(buf.rows[0][0].fg)
    }

    // MARK: - SGR: True Color (38;2;r;g;b / 48;2;r;g;b)

    func testTrueColorForeground() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[38;2;10;20;30mX")
        XCTAssertEqual(buf.rows[0][0].fg, Color(red: 10.0 / 255, green: 20.0 / 255, blue: 30.0 / 255))
    }

    func testTrueColorBackground() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[48;2;255;255;255mX")
        XCTAssertEqual(buf.rows[0][0].bg, Color(red: 1.0, green: 1.0, blue: 1.0))
    }

    /// Efter en 256-färgsekvens ska nästa SGR-parameter i SAMMA sekvens
    /// tolkas som en NY, separat parameter — inte råka konsumeras av
    /// `extendedColor`s index-hopp (`i += consumed`).
    func testParameterAfterExtendedColorIsStillParsedCorrectly() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[38;5;196;1mX") // röd + bold i samma sekvens
        XCTAssertEqual(buf.rows[0][0].fg, Color(red: 1.0, green: 0.0, blue: 0.0))
        XCTAssertTrue(buf.rows[0][0].bold)
    }

    // MARK: - Trasiga/ofullständiga sekvenser: ska inte krascha

    func testTruncated256ColorSequenceIsIgnoredGracefully() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        // "38;5" utan färgvärdet efter — extendedColor ska ge nil, inte
        // krascha på ett array-index utanför gränserna.
        buf.feed("\u{1B}[38;5mX")
        XCTAssertNil(buf.rows[0][0].fg)
        XCTAssertEqual(buf.rows[0][0].char, "X")
    }

    func testTruncatedTrueColorSequenceIsIgnoredGracefully() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[38;2;10;20mX") // saknar blått värde
        XCTAssertNil(buf.rows[0][0].fg)
        XCTAssertEqual(buf.rows[0][0].char, "X")
    }

    func testBareExtendedColorMarkerWithNoFollowupIsIgnored() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[38mX") // bara "38", inget läge alls
        XCTAssertNil(buf.rows[0][0].fg)
        XCTAssertEqual(buf.rows[0][0].char, "X")
    }

    // MARK: - Escape-sekvens delad över två feed()-anrop

    func testEscapeSequenceSplitAcrossTwoFeedCallsStillParsesCorrectly() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}[3")
        buf.feed("1mX")
        XCTAssertEqual(buf.rows[0][0].fg, Color(red: 0.75, green: 0.15, blue: 0.15))
        XCTAssertEqual(buf.rows[0][0].char, "X")
    }

    func testEscapeByteAloneInOneChunkThenBracketInNext() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        buf.feed("\u{1B}")
        buf.feed("[32mX")
        XCTAssertEqual(buf.rows[0][0].fg, Color(red: 0.15, green: 0.65, blue: 0.15))
    }

    // MARK: - OSC (t.ex. fönstertitel) avslutas av BEL, stör inte efterföljande text

    func testOSCSequenceTerminatedByBELDoesNotLeakIntoVisibleText() {
        let buf = TerminalBuffer(cols: 20, rows: 1)
        buf.feed("\u{1B}]0;window title\u{07}Hi")
        XCTAssertEqual(buf.rows[0][0].char, "H")
        XCTAssertEqual(buf.rows[0][1].char, "i")
    }

    // MARK: - revision

    func testRevisionBumpsExactlyOncePerFeedCall() {
        let buf = TerminalBuffer(cols: 5, rows: 1)
        XCTAssertEqual(buf.revision, 0)
        buf.feed("abc\u{1B}[31mdef")
        XCTAssertEqual(buf.revision, 1)
        buf.feed("g")
        XCTAssertEqual(buf.revision, 2)
    }
}
