import XCTest
@testable import SSHCore

final class SSHConfigTests: XCTestCase {
    // Idiomatisk OpenSSH: specifika block först, catch-all sist ("första vinner").
    let sample = """
    Host web prod-web
        HostName 10.0.0.5
        User deploy
        Port 2222
        IdentityFile ~/.ssh/deploy_ed25519

    Host *.internal
        User admin

    Host bastion-*
        ProxyJump jump.example.com

    Host !secret *
        User fallback
    """

    func testExactAliasWithAllFields() {
        let r = SSHConfig(text: sample).resolve("web")
        XCTAssertEqual(r.hostName, "10.0.0.5")
        XCTAssertEqual(r.user, "deploy")
        XCTAssertEqual(r.port, 2222)
        XCTAssertEqual(r.identityFile, (("~/.ssh/deploy_ed25519") as NSString).expandingTildeInPath)
    }

    func testSecondPatternOnSameHostLine() {
        XCTAssertEqual(SSHConfig(text: sample).resolve("prod-web").hostName, "10.0.0.5")
    }

    func testWildcardSuffix() {
        let r = SSHConfig(text: sample).resolve("db1.internal")
        XCTAssertEqual(r.user, "admin")          // *.internal matchar först
        XCTAssertEqual(r.hostName, "db1.internal") // ingen HostName -> aliaset
    }

    func testWildcardPrefixAndProxyJump() {
        XCTAssertEqual(SSHConfig(text: sample).resolve("bastion-eu").proxyJump, "jump.example.com")
    }

    func testFirstValueWins() {
        // "web" matchar både sitt eget block (User deploy) och "!secret *" (User fallback).
        // Första vinner.
        XCTAssertEqual(SSHConfig(text: sample).resolve("web").user, "deploy")
    }

    func testNegationExcludes() {
        // "secret" exkluderas av "!secret *" -> matchar inget block -> ingen User.
        let r = SSHConfig(text: sample).resolve("secret")
        XCTAssertNil(r.user)
        XCTAssertEqual(r.hostName, "secret")
    }

    func testUnknownAliasHitsCatchAll() {
        let r = SSHConfig(text: sample).resolve("random")
        XCTAssertEqual(r.hostName, "random")
        XCTAssertEqual(r.user, "fallback")   // "!secret *" catch-all
        XCTAssertEqual(r.port, 22)
    }

    func testEqualsAndSpacedSyntax() {
        let cfg = SSHConfig(text: "Host x\n  HostName=1.2.3.4\n  Port = 2200")
        let r = cfg.resolve("x")
        XCTAssertEqual(r.hostName, "1.2.3.4")
        XCTAssertEqual(r.port, 2200)
    }

    func testGlob() {
        XCTAssertTrue(SSHConfig.glob("*.internal", "a.internal"))
        XCTAssertTrue(SSHConfig.glob("bastion-*", "bastion-eu-1"))
        XCTAssertTrue(SSHConfig.glob("h??t", "host"))
        XCTAssertFalse(SSHConfig.glob("h??t", "hot"))
        XCTAssertFalse(SSHConfig.glob("*.internal", "internal"))
        XCTAssertTrue(SSHConfig.glob("*", "anything"))
    }
}
