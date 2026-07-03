import XCTest
@testable import SSHCore

// Okrypterad Ed25519-nyckel skapad av `ssh-keygen -t ed25519 -N ""` (kastnyckel).
private let fixturePEM = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACBqBA5UJW0LPhSwF8TDcOs6ETR1i6DKQwXq5hlduzfHLQAAAJhquF1Sarhd
UgAAAAtzc2gtZWQyNTUxOQAAACBqBA5UJW0LPhSwF8TDcOs6ETR1i6DKQwXq5hlduzfHLQ
AAAEDdTpYFU0fw0Bm4KQzn0+FRUKOMJhwNHLBWJn7k8xQCMGoEDlQlbQs+FLAXxMNw6zoR
NHWLoMpDBermGV27N8ctAAAAD2Jhc3Rpb24tZml4dHVyZQECAwQFBg==
-----END OPENSSH PRIVATE KEY-----
"""
private let expectedSeedHex = "dd4e96055347f0d019b8290ce7d3e15150a38c261c0d1cb056267ee4f3140230"

final class KeyParserTests: XCTestCase {
    func testParseEd25519Seed() throws {
        guard case .ed25519Seed(let seed) = try OpenSSHPrivateKey.parse(fixturePEM) else {
            return XCTFail("förväntade Ed25519-frö")
        }
        XCTAssertEqual(seed.map { String(format: "%02x", $0) }.joined(), expectedSeedHex)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try OpenSSHPrivateKey.parse("inte en nyckel"))
    }

    // Bevisar hela vägen: parsa nyckel -> signera handshake -> servern accepterar.
    // Fel parsning ger ogiltig signatur och auth misslyckas.
    func testParsedKeyAuthenticatesEndToEnd() async throws {
        let server = try LoopbackServer.start(password: "irrelevant")
        defer { server.shutdown() }

        let auth = try OpenSSHPrivateKey.parse(fixturePEM)
        let session = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: server.port, username: "tester"),
            auth: auth, knownHosts: KnownHosts(path: nil))
        try await session.connect()
        let output = try await session.run("whoami")
        await session.close()

        XCTAssertEqual(output, "ran: whoami\n")
    }
}
