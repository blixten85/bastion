import XCTest
@testable import SSHCore

final class ProxyJumpTests: XCTestCase {
    /// End-to-end: en RIKTIG jump-server (öppnar en genuin utgående
    /// anslutning till målet, ekar inte) + en SEPARAT, oberoende målserver.
    /// Ansluter till jump-servern normalt, sedan till målservern GENOM
    /// jump-sessionen (`connect(via:)`) — och kör ett kommando på målet för
    /// att bevisa att det verkligen är MÅLETS egen SSH-handskakning/auth/
    /// exec-hantering som svarar, inte jump-servern som på något sätt
    /// smugit igenom svaret.
    func testConnectViaJumpReachesSeparateTargetServer() async throws {
        let jumpServer = try LoopbackServer.start(password: "jump-pw", realDirectTCPIPForwarding: true)
        defer { jumpServer.shutdown() }
        let targetServer = try LoopbackServer.start(password: "target-pw")
        defer { targetServer.shutdown() }

        let jump = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: jumpServer.port, username: "tester"),
            auth: .password("jump-pw"), knownHosts: KnownHosts(path: nil))
        try await jump.connect()

        let target = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: targetServer.port, username: "tester"),
            auth: .password("target-pw"), knownHosts: KnownHosts(path: nil))
        try await target.connect(via: jump)

        let output = try await target.run("echo hello")
        XCTAssertEqual(output, "ran: echo hello\n")

        await target.close()
        await jump.close()
    }

    /// Fel lösenord för MÅLET (men rätt för jump) ska fortfarande misslyckas
    /// — bevisar att målets egen autentisering faktiskt kontrolleras genom
    /// tunneln, inte bara att jump-hoppet i sig lyckades.
    func testConnectViaJumpFailsWithWrongTargetPassword() async throws {
        let jumpServer = try LoopbackServer.start(password: "jump-pw", realDirectTCPIPForwarding: true)
        defer { jumpServer.shutdown() }
        let targetServer = try LoopbackServer.start(password: "target-pw")
        defer { targetServer.shutdown() }

        let jump = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: jumpServer.port, username: "tester"),
            auth: .password("jump-pw"), knownHosts: KnownHosts(path: nil))
        try await jump.connect()

        let target = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: targetServer.port, username: "tester"),
            auth: .password("helt fel"), knownHosts: KnownHosts(path: nil))
        do {
            try await target.connect(via: jump)
            _ = try await target.run("whoami")
            XCTFail("skulle ha misslyckats — fel lösenord för målet")
        } catch {
            // förväntat
        }

        await target.close()
        await jump.close()
    }

    func testConnectViaUnconnectedJumpThrows() async throws {
        let jump = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: 1, username: "tester"),
            auth: .password("x"), knownHosts: KnownHosts(path: nil))
        // jump.connect() anropas medvetet ALDRIG.

        let target = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: 2, username: "tester"),
            auth: .password("y"), knownHosts: KnownHosts(path: nil))
        do {
            try await target.connect(via: jump)
            XCTFail("skulle ha kastat — jump är inte ansluten")
        } catch let SSHError.channelFailed(message) {
            XCTAssertTrue(message.contains("inte ansluten"))
        }
        // Måste stängas även i felvägen — annars läcker sessionernas interna
        // "fatal"-promise (NIOs egen läckage-detektor kraschar i debug-läge
        // annars, `EventLoopFuture.deinit`). Upptäckt genom att just DEN HÄR
        // testen kraschade innan den här raden fanns.
        await target.close()
        await jump.close()
    }

    /// Dokumenterad stängningsordning: target FÖRE jump (target-kanalen
    /// lever på jumps event loop-grupp, se doc-kommentaren på
    /// `connect(via:)`). Bevisad med den omvända, FELAKTIGA ordningen under
    /// utveckling: `jump.close()` följt av `target.close()` hängde hela
    /// processen (jumps event loop-grupp var redan nedstängd när target
    /// försökte schemalägga sin egen kanalstängning på den) — inte bara ett
    /// teoretiskt påstående i doc-kommentaren, utan en riktig bugg som
    /// bevisligen kraschade/hängde innan den upptäcktes just genom det här
    /// testet.
    func testCorrectCloseOrderTargetThenJumpDoesNotHang() async throws {
        let jumpServer = try LoopbackServer.start(password: "jump-pw", realDirectTCPIPForwarding: true)
        defer { jumpServer.shutdown() }
        let targetServer = try LoopbackServer.start(password: "target-pw")
        defer { targetServer.shutdown() }

        let jump = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: jumpServer.port, username: "tester"),
            auth: .password("jump-pw"), knownHosts: KnownHosts(path: nil))
        try await jump.connect()

        let target = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: targetServer.port, username: "tester"),
            auth: .password("target-pw"), knownHosts: KnownHosts(path: nil))
        try await target.connect(via: jump)
        _ = try await target.run("echo still alive")

        await target.close()
        await jump.close()
    }
}
