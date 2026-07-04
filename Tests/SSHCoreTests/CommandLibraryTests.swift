import XCTest
@testable import SSHCore

final class CommandLibraryTests: XCTestCase {
    func testAllEntriesHaveUniqueIDs() {
        let ids = CommandLibrary.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "dubbletter av (kategori, kommando) hittades")
    }

    func testAllCategoriesRepresented() {
        // VISION.md: "Docker, Linux, Git, Cloudflare, Tailscale, WireGuard, systemd"
        let represented = Set(CommandLibrary.all.map(\.category))
        XCTAssertEqual(represented, Set(CommandLibraryEntry.Category.allCases))
    }

    func testEntriesFilteredByCategory() {
        let docker = CommandLibrary.entries(in: .docker)
        XCTAssertFalse(docker.isEmpty)
        XCTAssertTrue(docker.allSatisfy { $0.category == .docker })
    }

    func testNoEntryIsEmpty() {
        for entry in CommandLibrary.all {
            XCTAssertFalse(entry.command.trimmingCharacters(in: .whitespaces).isEmpty, entry.id)
            XCTAssertFalse(entry.summary.trimmingCharacters(in: .whitespaces).isEmpty, entry.id)
        }
    }

    func testAsSnippetRendersVariablesLikeARealSnippet() {
        let entry = CommandLibraryEntry(category: .docker, command: "docker compose restart {{service}}", summary: "test")
        XCTAssertEqual(entry.asSnippet.variableNames, ["service"])
        XCTAssertEqual(entry.asSnippet.rendered(with: ["service": "plex"]), "docker compose restart plex")
    }
}
