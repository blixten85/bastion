import XCTest
@testable import SSHCore

final class KnownHostsTests: XCTestCase {
    func testTOFUVerdicts() {
        let store = KnownHosts(path: nil)
        let keyA = "ssh-ed25519 AAAAkeyA"
        let keyB = "ssh-ed25519 AAAAkeyB"

        XCTAssertEqual(store.check(host: "h", port: 22, keyString: keyA), .learned)
        XCTAssertEqual(store.check(host: "h", port: 22, keyString: keyA), .trusted)
        XCTAssertEqual(store.check(host: "h", port: 22, keyString: keyB), .changed(stored: keyA))
        // Annan port är en annan identitet.
        XCTAssertEqual(store.check(host: "h", port: 2222, keyString: keyB), .learned)
    }

    func testFilePersistsAndReloads() throws {
        let dir = NSTemporaryDirectory() + "bastion-kh-\(ProcessInfo.processInfo.processIdentifier)"
        let path = dir + "/known_hosts"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let s1 = KnownHosts(path: path)
        XCTAssertEqual(s1.check(host: "srv", port: 22, keyString: "ssh-ed25519 AAAAx"), .learned)

        // Ny instans läser samma fil -> minns nyckeln.
        let s2 = KnownHosts(path: path)
        XCTAssertEqual(s2.check(host: "srv", port: 22, keyString: "ssh-ed25519 AAAAx"), .trusted)
        XCTAssertEqual(s2.check(host: "srv", port: 22, keyString: "ssh-ed25519 AAAAy"),
                       .changed(stored: "ssh-ed25519 AAAAx"))
    }

    // Positiv väg: okänd värd lärs in, återanslutning litar på samma nyckel.
    func testLearnThenTrustEndToEnd() async throws {
        let server = try LoopbackServer.start(password: "pw")
        defer { server.shutdown() }
        let store = KnownHosts(path: nil)
        let target = SSHTarget(host: "127.0.0.1", port: server.port, username: "t")

        let s1 = SSHSession(target: target, auth: .password("pw"), knownHosts: store)
        try await s1.connect()
        _ = try await s1.run("echo hej")
        await s1.close()

        let s2 = SSHSession(target: target, auth: .password("pw"), knownHosts: store)
        try await s2.connect()
        let out = try await s2.run("echo igen")
        await s2.close()
        XCTAssertEqual(out, "ran: echo igen\n")
    }

    // MITM-väg: lagrad nyckel skiljer sig från serverns -> anslutning avvisas.
    func testChangedHostKeyRejected() async throws {
        let server = try LoopbackServer.start(password: "pw")
        defer { server.shutdown() }
        let store = KnownHosts(path: nil)
        // Förgifta lagringen med en annan nyckel för exakt denna host:port.
        _ = store.check(host: "127.0.0.1", port: server.port,
                        keyString: "ssh-ed25519 AAAAforfalskad")

        let session = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: server.port, username: "t"),
            auth: .password("pw"), knownHosts: store)
        do {
            try await session.connect()
            _ = try await session.run("id")
            await session.close()
            XCTFail("ändrad värdnyckel borde avvisas")
        } catch {
            await session.close()   // förväntat
        }
    }
}
