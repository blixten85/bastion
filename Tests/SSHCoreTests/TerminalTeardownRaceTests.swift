import XCTest
@testable import SSHCore

// Regressionstest för PR #155 (dubbel-bild-korruption i terminalvyn vid
// dismiss) och dess uppföljning (f8d13dd, "isStopped"-racefixen). Den
// UI-bundna `SSHTerminalController` (App/TerminalView.swift) är
// Xcode-only och kan inte köras här, men hela dess korrekthet vilar på
// ett enda löfte från SSHCore-lagret: att `SSHSession.close()`/
// `SSHShell.close()` verkligen avslutar `shell.output`-strömmen inom
// rimlig tid, oavsett NÄR under sessionens livscykel den anropas. Det är
// exakt det löftet dessa tester bevisar.
final class TerminalTeardownRaceTests: XCTestCase {
    func testCloseDuringActiveShellTerminatesOutputStreamPromptly() async throws {
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }

        let session = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: server.port, username: "tester"),
            auth: .password("hunter2"), knownHosts: KnownHosts(path: nil))
        try await session.connect()
        let shell = try await session.openShell(cols: 80, rows: 24)

        // Motsvarar dismiss MEDAN sessionen är aktiv (ingen väntan på
        // specifikt innehåll) - precis det scenario stop() i
        // SSHTerminalController hanterar.
        shell.close()
        await session.close()

        // close() signalerar `fatal`, vilket avslutar strömmen med ett kastat
        // SSHError (se openShell()) snarare än en tyst completion - exakt det
        // TerminalView.swifts start()-loop redan förväntar sig och fångar via
        // sin egen `catch { guard !isStopped else { return } ... }`. Om
        // teardown inte faktiskt stänger kanalen hänger den här loopen för
        // evigt istället och testet timear ut i CI - en giltig (om än mindre
        // precis) regressionsdetektor.
        var chunkCount = 0
        do {
            for try await _ in shell.output {
                chunkCount += 1
            }
            XCTFail("strömmen skulle avslutas med ett kastat fel efter close(), inte tyst")
        } catch {
            // Förväntat: close() -> signalFatal -> strömmen kastar.
        }
        XCTAssertEqual(chunkCount, 0, "ingen mer data skulle levereras efter close()")
    }

    func testCloseImmediatelyAfterConnectLeavesNoOrphanedSession() async throws {
        // Motsvarar det ursprungliga CodeRabbit-fyndet på #155: dismiss
        // som landar precis EFTER connect() men FÖRE/UNDER openShell().
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }

        let session = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: server.port, username: "tester"),
            auth: .password("hunter2"), knownHosts: KnownHosts(path: nil))
        try await session.connect()
        await session.close()

        // Sessionen är stängd - en efterföljande openShell() ska faila
        // rent (kanalen är borta) istället för att hänga eller lyckas mot
        // en föräldralös anslutning servern redan tappat räkningen på.
        do {
            _ = try await session.openShell(cols: 80, rows: 24)
            XCTFail("openShell() efter close() borde faila, inte lyckas mot en död session")
        } catch {
            // Förväntat: kanalen är stängd.
        }
    }
}
