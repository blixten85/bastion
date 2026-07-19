import XCTest
@testable import SSHCore

final class TailscaleStatusTests: XCTestCase {
    /// Riktig `tailscale status --json`-utskrift, fångad från en genuint
    /// installerad och startad `tailscaled` (v1.98.8) på den här maskinen
    /// (`mp100`) — inte handskriven. Ingen inloggad tailnet-anslutning
    /// gjordes (kräver riktiga kontouppgifter), så `Peer` är `null` här —
    /// det ärliga, verifierbara läget utan att logga in på någons riktiga
    /// tailnet i en testkörning.
    private let realNoLoginJSON = """
    {
      "Version": "1.98.8-t1241b225b-g0520dfda5",
      "TUN": true,
      "BackendState": "NeedsLogin",
      "AuthURL": "",
      "TailscaleIPs": null,
      "Self": {
        "ID": "",
        "PublicKey": "nodekey:0000000000000000000000000000000000000000000000000000000000000000",
        "HostName": "mp100",
        "DNSName": "",
        "OS": "linux",
        "UserID": 0,
        "TailscaleIPs": null,
        "Online": false
      },
      "Health": ["Tailscale is stopped."],
      "MagicDNSSuffix": "",
      "CurrentTailnet": null,
      "CertDomains": null,
      "Peer": null,
      "User": null,
      "ClientVersion": null
    }
    """

    func testParsesRealNeedsLoginStatus() throws {
        let status = try TailscaleStatus.parse(jsonData: Data(realNoLoginJSON.utf8))
        XCTAssertEqual(status.version, "1.98.8-t1241b225b-g0520dfda5")
        XCTAssertEqual(status.backendState, "NeedsLogin")
        XCTAssertEqual(status.selfNode?.hostName, "mp100")
        XCTAssertEqual(status.selfNode?.os, "linux")
        XCTAssertNil(status.peer)
    }

    func testSuggestedHostsEmptyWithoutPeers() throws {
        let status = try TailscaleStatus.parse(jsonData: Data(realNoLoginJSON.utf8))
        XCTAssertTrue(status.suggestedHosts.isEmpty)
    }

    /// `Peer`-posterna delar samma `PeerStatus`-Go-typ som `Self` i
    /// Tailscales egen källkod (verifierat via källkodsläsning, se
    /// TailscaleStatus.swifts doc-kommentar) — den här fixturen återanvänder
    /// alltså SAMMA fältnamn som den riktiga `Self`-utskriften ovan bevisade,
    /// bara ifylld med rimliga exempelvärden istället för att vara fångad
    /// från en riktig inloggad tailnet-session (skulle kräva riktiga
    /// kontouppgifter i en testkörning, olämpligt).
    private let withPeersJSON = """
    {
      "Version": "1.98.8-t1241b225b-g0520dfda5",
      "BackendState": "Running",
      "Self": {"HostName": "mp100", "DNSName": "mp100.tail1234.ts.net.", "OS": "linux", "TailscaleIPs": ["100.64.0.1"], "Online": true},
      "Peer": {
        "nodekey:aaa": {"HostName": "nas", "DNSName": "nas.tail1234.ts.net.", "OS": "linux", "TailscaleIPs": ["100.64.0.2"], "Online": true},
        "nodekey:bbb": {"HostName": "laptop", "DNSName": "", "OS": "macOS", "TailscaleIPs": ["100.64.0.3"], "Online": false}
      }
    }
    """

    func testSuggestedHostsOnlyIncludesOnlinePeersWithAnIP() throws {
        let status = try TailscaleStatus.parse(jsonData: Data(withPeersJSON.utf8))
        let suggested = status.suggestedHosts
        XCTAssertEqual(suggested.count, 1)
        XCTAssertEqual(suggested.first?.hostName, "nas.tail1234.ts.net")
        XCTAssertEqual(suggested.first?.address, "100.64.0.2")
    }

    // MARK: - fetchLocal (riktig, kortlivad process — inte mockad)

    /// Skriver ett riktigt, körbart `/bin/sh`-skript som skriver ut angiven
    /// text på stdout (eller stderr + given exitkod) och returnerar dess
    /// sökväg. Städas av `addTeardownBlock`.
    private func makeScript(_ body: String) throws -> URL {
        let path = NSTemporaryDirectory() + "ts-fixture-\(UUID().uuidString).sh"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return URL(fileURLWithPath: path)
    }

    // `withTimeout` (definierad i TerminalTeardownRaceTests.swift, samma
    // testmål) skyddar mot ett Process/Pipe-dödläge om regressionsfixen i
    // `fetchLocal` (konkurrent stdout/stderr-läsning) någonsin bryts.
    func testFetchLocalParsesRealProcessOutput() async throws {
        let script = try makeScript("#!/bin/sh\ncat <<'EOF'\n\(withPeersJSON)\nEOF\n")
        let status = try await withTimeout(seconds: 10) {
            try TailscaleStatus.fetchLocal(executableURL: script, arguments: [])
        }
        XCTAssertEqual(status.backendState, "Running")
        XCTAssertEqual(status.suggestedHosts.first?.address, "100.64.0.2")
    }

    func testFetchLocalThrowsOnNonZeroExit() async throws {
        let script = try makeScript("#!/bin/sh\necho 'tailscale: not logged in' >&2\nexit 1\n")
        do {
            _ = try await withTimeout(seconds: 10) {
                try TailscaleStatus.fetchLocal(executableURL: script, arguments: [])
            }
            XCTFail("förväntade att fetchLocal skulle kasta")
        } catch let error as TailscaleStatusError {
            guard case .localCommandFailed(let code, let stderr) = error else {
                return XCTFail("fel feltyp: \(error)")
            }
            XCTAssertEqual(code, 1)
            XCTAssertTrue(stderr.contains("not logged in"))
        }
    }
}
