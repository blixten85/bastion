import XCTest
import Foundation
@testable import SSHCore

final class ArchiveOperationsTests: XCTestCase {
    // MARK: - Citering (shell-injektionssäkerhet)

    func testShellQuoteEscapesEmbeddedSingleQuotes() {
        XCTAssertEqual(ArchiveOperations.shellQuote("plain"), "'plain'")
        XCTAssertEqual(ArchiveOperations.shellQuote("with space"), "'with space'")
        XCTAssertEqual(ArchiveOperations.shellQuote("it's"), "'it'\\''s'")
    }

    /// Bevisar att en filnamn-injektion FAKTISKT nollställs av citeringen —
    /// inte bara att strängen "ser rätt ut", utan att en RIKTIG shell (via
    /// `/bin/sh -c`) tolkar hela kommandot som EN sökväg, inte som ett
    /// avslutat citat + ett nytt kommando.
    func testShellQuoteSurvivesRealShellParsing() throws {
        let malicious = "innocent'; touch /tmp/bastion-injection-proof-\(UUID().uuidString); echo '"
        let quoted = ArchiveOperations.shellQuote(malicious)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' \(quoted)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(output, malicious)
    }

    // MARK: - Kommandobyggare (rena strängar, ingen server)

    func testCreateTarGzCommand() {
        XCTAssertEqual(
            ArchiveOperations.createTarGzCommand(paths: ["a.txt", "b.txt"], archiveName: "out.tar.gz", in: "/home/x"),
            "cd '/home/x' && tar czf 'out.tar.gz' -- 'a.txt' 'b.txt'")
    }

    func testExtractTarGzCommand() {
        XCTAssertEqual(
            ArchiveOperations.extractTarGzCommand(archiveName: "out.tar.gz", in: "/home/x"),
            "cd '/home/x' && tar xzf 'out.tar.gz'")
    }

    func testCreateZipCommand() {
        XCTAssertEqual(
            ArchiveOperations.createZipCommand(paths: ["a.txt"], archiveName: "out.zip", in: "/home/x"),
            "cd '/home/x' && zip -r -q 'out.zip' 'a.txt'")
    }

    func testExtractZipCommand() {
        XCTAssertEqual(
            ArchiveOperations.extractZipCommand(archiveName: "out.zip", in: "/home/x"),
            "cd '/home/x' && unzip -o -q 'out.zip'")
    }

    // MARK: - Riktig körning mot en RIKTIG tar/zip (LoopbackServer realExec: true)

    private func connectedRealExecSession(_ server: LoopbackServer) async throws -> SSHSession {
        let session = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: server.port, username: "tester"),
            auth: .password("hunter2"), knownHosts: KnownHosts(path: nil))
        try await session.connect()
        return session
    }

    func testCreateThenExtractTarGzRoundTripsRealFiles() async throws {
        let server = try LoopbackServer.start(password: "hunter2", realExec: true)
        defer { server.shutdown() }
        let session = try await connectedRealExecSession(server)

        try "hej".write(toFile: server.sftpRoot + "/a.txt", atomically: true, encoding: .utf8)
        try "då".write(toFile: server.sftpRoot + "/b.txt", atomically: true, encoding: .utf8)

        try await ArchiveOperations.createTarGz(
            paths: ["a.txt", "b.txt"], archiveName: "bundle.tar.gz", in: server.sftpRoot, over: session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: server.sftpRoot + "/bundle.tar.gz"))

        let extractDir = server.sftpRoot + "/extracted"
        try FileManager.default.createDirectory(atPath: extractDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: server.sftpRoot + "/bundle.tar.gz", toPath: extractDir + "/bundle.tar.gz")
        try await ArchiveOperations.extractTarGz(archiveName: "bundle.tar.gz", in: extractDir, over: session)

        XCTAssertEqual(try String(contentsOfFile: extractDir + "/a.txt", encoding: .utf8), "hej")
        XCTAssertEqual(try String(contentsOfFile: extractDir + "/b.txt", encoding: .utf8), "då")

        await session.close()
    }

    func testCreateThenExtractZipRoundTripsRealFiles() async throws {
        let server = try LoopbackServer.start(password: "hunter2", realExec: true)
        defer { server.shutdown() }
        let session = try await connectedRealExecSession(server)

        try "innehåll".write(toFile: server.sftpRoot + "/c.txt", atomically: true, encoding: .utf8)

        try await ArchiveOperations.createZip(
            paths: ["c.txt"], archiveName: "bundle.zip", in: server.sftpRoot, over: session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: server.sftpRoot + "/bundle.zip"))

        let extractDir = server.sftpRoot + "/extracted-zip"
        try FileManager.default.createDirectory(atPath: extractDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: server.sftpRoot + "/bundle.zip", toPath: extractDir + "/bundle.zip")
        try await ArchiveOperations.extractZip(archiveName: "bundle.zip", in: extractDir, over: session)

        XCTAssertEqual(try String(contentsOfFile: extractDir + "/c.txt", encoding: .utf8), "innehåll")

        await session.close()
    }

    /// En filnamn-injektion i `paths` får INTE läcka utanför tar-kommandot
    /// när det faktiskt körs mot en RIKTIG shell — inte bara att
    /// kommandosträngen "ser citerad ut" (se ovan), utan att den skadliga
    /// filen aldrig skapas när kommandot verkligen exekveras.
    func testCreateTarGzRejectsInjectionAttemptInPathAgainstRealShell() async throws {
        let server = try LoopbackServer.start(password: "hunter2", realExec: true)
        defer { server.shutdown() }
        let session = try await connectedRealExecSession(server)

        try "x".write(toFile: server.sftpRoot + "/real.txt", atomically: true, encoding: .utf8)
        let proofPath = server.sftpRoot + "/injected.txt"
        let malicious = "real.txt'; touch '\(proofPath)"

        // tar klagar (ingen sådan fil) men ska INTE köra det inbäddade
        // `touch`-kommandot — testar bara att injektionsfilen aldrig dyker upp.
        _ = try? await ArchiveOperations.createTarGz(
            paths: [malicious], archiveName: "bundle2.tar.gz", in: server.sftpRoot, over: session)

        XCTAssertFalse(FileManager.default.fileExists(atPath: proofPath))

        await session.close()
    }
}
