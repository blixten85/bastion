import XCTest
@testable import SSHCore

private typealias Host = SSHCore.Host

final class ImportAndExecTests: XCTestCase {
    let config = """
    Host web prod-web
        HostName 10.0.0.5
        User deploy
        Port 2222
        IdentityFile ~/.ssh/deploy_ed25519

    Host nas
        HostName 10.0.0.2
        User root

    Host *.internal
        User admin

    Host nouser
        HostName 10.0.0.9
    """

    func testHostAliasesSkipWildcards() {
        XCTAssertEqual(SSHConfig(text: config).hostAliases, ["web", "prod-web", "nas", "nouser"])
    }

    func testImportedHosts() {
        let hosts = Host.imported(from: SSHConfig(text: config))
        // "nouser" saknar User -> hoppas över; *.internal är jokertecken.
        XCTAssertEqual(hosts.map { $0.alias }.sorted(), ["nas", "prod-web", "web"])
        let web = hosts.first { $0.alias == "web" }!
        XCTAssertEqual(web.hostName, "10.0.0.5")
        XCTAssertEqual(web.user, "deploy")
        XCTAssertEqual(web.port, 2222)
        XCTAssertEqual(web.auth, .keyFile(("~/.ssh/deploy_ed25519" as NSString).expandingTildeInPath))
        XCTAssertEqual(hosts.first { $0.alias == "nas" }?.auth, .agentDefault)
    }

    func testImportSkipsDuplicatesOnReimport() {
        let store = HostStore(path: nil)
        XCTAssertEqual(store.importSSHConfig(config).count, 3)
        XCTAssertEqual(store.importSSHConfig(config).count, 0)   // re-import lägger inte till igen
        XCTAssertEqual(store.all().count, 3)
    }

    func testDockerExecShellCommandValidatedAndFormed() throws {
        XCTAssertEqual(try DockerService.execShellCommand("plex"),
                       "docker exec -it plex sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
        XCTAssertThrowsError(try DockerService.execShellCommand("plex; rm -rf /"))
    }
}
