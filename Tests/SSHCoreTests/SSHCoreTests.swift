import XCTest
@testable import SSHCore

final class SSHCoreTests: XCTestCase {
    func testConnectAuthExecStream() async throws {
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }

        let session = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: server.port, username: "tester"),
            auth: .password("hunter2"), knownHosts: KnownHosts(path: nil))
        try await session.connect()
        let output = try await session.run("uname -a")
        await session.close()

        XCTAssertEqual(output, "ran: uname -a\n")
    }

    func testTwoSequentialCommandsOnOneConnection() async throws {
        // Docker-vyn kör flera kommandon i följd på samma anslutning (nya
        // exec-kanaler). Verifiera att multiplexering funkar.
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }
        let session = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: server.port, username: "tester"),
            auth: .password("hunter2"), knownHosts: KnownHosts(path: nil))
        try await session.connect()
        let first = try await session.run("one")
        let second = try await session.run("two")
        await session.close()
        XCTAssertEqual(first, "ran: one\n")
        XCTAssertEqual(second, "ran: two\n")
    }

    func testInteractiveShellEchoes() async throws {
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }

        let session = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: server.port, username: "tester"),
            auth: .password("hunter2"), knownHosts: KnownHosts(path: nil))
        try await session.connect()
        let shell = try await session.openShell(cols: 120, rows: 40)
        shell.resize(cols: 100, rows: 30)
        shell.send("hello world\n")

        // Läs tills echo-shellen speglat tillbaka vår rad (eller strömmen tar slut).
        var seen = ""
        for try await chunk in shell.output {
            seen += chunk.text
            if seen.contains("hello world\n") { break }
        }
        shell.close()
        await session.close()

        XCTAssertTrue(seen.contains("hello world\n"), "fick: \(seen.debugDescription)")
    }

    func testWrongPasswordFails() async throws {
        let server = try LoopbackServer.start(password: "correct")
        defer { server.shutdown() }

        let session = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: server.port, username: "tester"),
            auth: .password("wrong"), knownHosts: KnownHosts(path: nil))

        do {
            try await session.connect()
            _ = try await session.run("id")
            await session.close()
            XCTFail("Fel lösenord borde inte lyckas")
        } catch {
            await session.close()
            // Förväntat: anslutningen/kanalen stängs av misslyckad auth.
        }
    }
}
