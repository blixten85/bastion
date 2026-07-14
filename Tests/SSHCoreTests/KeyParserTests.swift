import XCTest
@testable import SSHCore

final class KeyParserTests: XCTestCase {
    func testParseEd25519Seed() throws {
        let pair = KeyGenerator.generateEd25519(comment: "parser-test")
        let pem = try OpenSSHPrivateKey.export(seed: pair.seed, comment: pair.comment)
        guard case .ed25519Seed(let seed) = try OpenSSHPrivateKey.parse(pem) else {
            return XCTFail("förväntade Ed25519-frö")
        }
        XCTAssertEqual(seed, pair.seed)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try OpenSSHPrivateKey.parse("inte en nyckel"))
    }

    // Bevisar hela vägen: parsa nyckel -> signera handshake -> servern accepterar.
    // Fel parsning ger ogiltig signatur och auth misslyckas.
    func testParsedKeyAuthenticatesEndToEnd() async throws {
        let server = try LoopbackServer.start(password: "irrelevant")
        defer { server.shutdown() }

        let pair = KeyGenerator.generateEd25519(comment: "authentication-test")
        let pem = try OpenSSHPrivateKey.export(seed: pair.seed, comment: pair.comment)
        let auth = try OpenSSHPrivateKey.parse(pem)
        let session = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: server.port, username: "tester"),
            auth: auth, knownHosts: KnownHosts(path: nil))
        try await session.connect()
        let output = try await session.run("whoami")
        await session.close()

        XCTAssertEqual(output, "ran: whoami\n")
    }
}
