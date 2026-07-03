import XCTest
@testable import SSHCore

final class DockerServiceTests: XCTestCase {
    func testValidateAcceptsRealReferences() throws {
        for ok in ["plex", "a1b2c3d4e5f6", "my_app.1", "web-1", "Radarr"] {
            XCTAssertEqual(try DockerService.validate(ok), ok)
        }
    }

    func testValidateRejectsInjection() {
        for bad in ["plex; rm -rf /", "a b", "$(whoami)", "`id`", "a|b", "a&&b",
                    "", "-flag", "x\ny", "a'b", "a\"b", "a>b"] {
            XCTAssertThrowsError(try DockerService.validate(bad)) { error in
                XCTAssertEqual(error as? DockerError, .invalidReference(bad))
            }
        }
    }

    func testCommandBuilders() throws {
        XCTAssertEqual(try DockerService.startCommand("plex"), "docker start plex")
        XCTAssertEqual(try DockerService.stopCommand("plex"), "docker stop plex")
        XCTAssertEqual(try DockerService.restartCommand("plex"), "docker restart plex")
        XCTAssertEqual(try DockerService.logsCommand("plex", tail: 100), "docker logs --tail 100 plex 2>&1")
        XCTAssertEqual(try DockerService.logsCommand("plex", tail: 0), "docker logs --tail 1 plex 2>&1")
        XCTAssertEqual(DockerService.listCommand(all: true),
                       "docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null")
        XCTAssertEqual(DockerService.listCommand(all: false),
                       "docker ps --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null")
    }

    func testInjectionCannotReachCommandBuilder() {
        XCTAssertThrowsError(try DockerService.stopCommand("plex; rm -rf /"))
    }

    func testParseListRunningAndStopped() {
        let out = """
        a1b2c3|plex|linuxserver/plex:latest|Up 3 days
        d4e5f6|old|busybox|Exited (0) 2 hours ago
        """
        let list = DockerService.parseList(out)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].name, "plex")
        XCTAssertTrue(list[0].isRunning)
        XCTAssertEqual(list[1].name, "old")
        XCTAssertFalse(list[1].isRunning)
    }
}
