import XCTest
import Foundation
@testable import SSHCore

final class KeyGeneratorTests: XCTestCase {
    func testGeneratedPublicKeyLineHasCorrectFormat() {
        let pair = KeyGenerator.generateEd25519(comment: "bastion-test")
        XCTAssertTrue(pair.publicKeyLine.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(pair.publicKeyLine.hasSuffix("bastion-test"))
        XCTAssertEqual(pair.seed.count, 32)
    }

    func testTwoGeneratedKeysAreDistinct() {
        let a = KeyGenerator.generateEd25519()
        let b = KeyGenerator.generateEd25519()
        XCTAssertNotEqual(a.seed, b.seed)
        XCTAssertNotEqual(a.publicKeyLine, b.publicKeyLine)
    }

    func testCommentIsOptional() {
        let pair = KeyGenerator.generateEd25519()
        // Utan kommentar: exakt två delar ("ssh-ed25519" + base64), inget
        // efterföljande mellanslag+text.
        let parts = pair.publicKeyLine.split(separator: " ")
        XCTAssertEqual(parts.count, 2)
    }
}

final class OpenSSHPrivateKeyExportTests: XCTestCase {
    /// Rundresa genom EGEN kod: generera, exportera, parsa tillbaka — fröet
    /// måste vara identiskt. Enda sättet att bevisa en encoder utan en extern
    /// referens är att visa att den egna, redan verifierade decodern läser
    /// tillbaka exakt det den fick.
    func testExportThenParseRoundTripsSeed() throws {
        let pair = KeyGenerator.generateEd25519(comment: "roundtrip")
        let pem = try OpenSSHPrivateKey.export(seed: pair.seed, comment: "roundtrip")
        let auth = try OpenSSHPrivateKey.parse(pem)
        guard case .ed25519Seed(let parsedSeed) = auth else {
            return XCTFail("förväntade .ed25519Seed, fick \(auth)")
        }
        XCTAssertEqual(parsedSeed, pair.seed)
    }

    func testExportedPEMHasCorrectHeaderAndFooter() throws {
        let pair = KeyGenerator.generateEd25519()
        let pem = try OpenSSHPrivateKey.export(seed: pair.seed)
        XCTAssertTrue(pem.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        XCTAssertTrue(pem.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
    }

    func testRejectsWrongSeedLength() {
        XCTAssertThrowsError(try OpenSSHPrivateKey.export(seed: Data([1, 2, 3]))) { error in
            guard case SSHKeyError.malformed = error else {
                return XCTFail("förväntade .malformed, fick \(error)")
            }
        }
    }

    /// Starkaste möjliga verifiering: den REKTIGA `ssh-keygen` (inte vår egen
    /// kod) ska kunna läsa en exporterad nyckel och räkna ut samma publika
    /// nyckel som vi själva beräknade. Hoppar över om ssh-keygen saknas i
    /// testmiljön (t.ex. vissa CI-avbilder) i stället för att falskt misslyckas.
    func testRealSSHKeygenAcceptsExportedKey() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/ssh-keygen") else {
            throw XCTSkip("ssh-keygen saknas i den här miljön")
        }
        let pair = KeyGenerator.generateEd25519(comment: "keygen-cross-check")
        let pem = try OpenSSHPrivateKey.export(seed: pair.seed, comment: "keygen-cross-check")

        let dir = NSTemporaryDirectory() + "bastion-keygen-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let keyPath = dir + "/id_ed25519"
        try pem.write(toFile: keyPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-y", "-f", keyPath]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // ssh-keygen -y skriver "<typ> <base64> <kommentar>" — kommentaren
        // hämtas ur privatnyckelfilens eget kommentarfält, precis som vi
        // skrev in den. Jämför hela raden mot vår egen.
        XCTAssertEqual(output, pair.publicKeyLine)
    }
}

final class ShellQuotedTests: XCTestCase {
    /// Testar mot en RIKTIG `/bin/sh`, inte bara vår egen escape-logik mot sig
    /// själv — bevisar att skalet faktiskt tolkar den escapade strängen som
    /// EN literal sträng, oavsett vad den innehåller.
    private func roundTripThroughRealShell(_ input: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' \(shellQuoted(input))"]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    func testPlainString() throws {
        XCTAssertEqual(try roundTripThroughRealShell("hello world"), "hello world")
    }

    func testEmbeddedSingleQuote() throws {
        XCTAssertEqual(try roundTripThroughRealShell("it's a test"), "it's a test")
    }

    func testShellMetacharacters() throws {
        XCTAssertEqual(try roundTripThroughRealShell("$(rm -rf /) `whoami` ; & | > < \\"), "$(rm -rf /) `whoami` ; & | > < \\")
    }

    func testOnlyQuotes() throws {
        XCTAssertEqual(try roundTripThroughRealShell("''''"), "''''")
    }
}

final class DeployPublicKeyCommandTests: XCTestCase {
    func testCommandContainsCorrectPieces() {
        let cmd = deployPublicKeyCommand("ssh-ed25519 AAAAtest comment")
        XCTAssertTrue(cmd.contains("mkdir -p ~/.ssh"))
        XCTAssertTrue(cmd.contains("chmod 700 ~/.ssh"))
        XCTAssertTrue(cmd.contains("chmod 600 ~/.ssh/authorized_keys"))
        XCTAssertTrue(cmd.contains("grep -qxF"))
        XCTAssertTrue(cmd.contains("'ssh-ed25519 AAAAtest comment'"))
    }

    func testMaliciousCommentIsFullyQuotedNotInjected() {
        let malicious = "'; rm -rf ~ #"
        let cmd = deployPublicKeyCommand("ssh-ed25519 AAAAtest \(malicious)")
        // Den escapade formen ska finnas — INTE den råa, oescapade strängen
        // (vilket skulle betyda att den läckt ut ur citattecknen).
        XCTAssertFalse(cmd.contains("AAAAtest '; rm -rf ~ #'"))
    }
}

final class VerifyKeyAuthWorksTests: XCTestCase {
    func testSucceedsWithValidKeyAgainstRealServer() async throws {
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }
        let pair = KeyGenerator.generateEd25519()
        let ok = await SSHSession.verifyKeyAuthWorks(
            target: SSHTarget(host: "127.0.0.1", port: server.port, username: "tester"),
            seed: pair.seed, knownHosts: KnownHosts(path: nil))
        XCTAssertTrue(ok)
    }

    func testFailsAgainstUnreachableHost() async throws {
        let pair = KeyGenerator.generateEd25519()
        let ok = await SSHSession.verifyKeyAuthWorks(
            target: SSHTarget(host: "127.0.0.1", port: 1, username: "tester"),
            seed: pair.seed, knownHosts: KnownHosts(path: nil))
        XCTAssertFalse(ok)
    }
}
