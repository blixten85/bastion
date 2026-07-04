import XCTest
@testable import SSHCore

final class SnippetTests: XCTestCase {
    func testExtractsVariableNamesInOrderWithoutDuplicates() {
        let s = Snippet(name: "restart", template: "docker compose restart {{service}} in {{env}} ({{service}})")
        XCTAssertEqual(s.variableNames, ["service", "env"])
    }

    func testExtractsVariableNamesWithSurroundingWhitespace() {
        let s = Snippet(name: "restart", template: "docker compose restart {{ service }}")
        XCTAssertEqual(s.variableNames, ["service"])
    }

    func testRendersAllVariables() {
        let s = Snippet(name: "restart", template: "docker compose restart {{service}}")
        XCTAssertEqual(s.rendered(with: ["service": "plex"]), "docker compose restart plex")
    }

    func testRendersWhitespaceVariantSameAsPlain() {
        // Regression: en tidigare implementation extraherade "service" (trimmat)
        // men letade efter den otrimmade "{{service}}" vid ersättning, vilket
        // aldrig matchade "{{ service }}" (med mellanslag) — värdet visades
        // aldrig, {{ service }} blev kvar i klartext. Fångades av det här testet.
        let s = Snippet(name: "restart", template: "docker compose restart {{ service }}")
        XCTAssertEqual(s.rendered(with: ["service": "plex"]), "docker compose restart plex")
    }

    func testMissingValueRendersAsEmptyString() {
        let s = Snippet(name: "restart", template: "echo {{missing}}!")
        XCTAssertEqual(s.rendered(with: [:]), "echo !")
    }

    func testMultipleOccurrencesOfSameVariableAllReplaced() {
        let s = Snippet(name: "greet", template: "{{name}} says hi, {{name}}!")
        XCTAssertEqual(s.rendered(with: ["name": "Bob"]), "Bob says hi, Bob!")
    }

    func testNoVariablesRendersUnchanged() {
        let s = Snippet(name: "uptime", template: "uptime")
        XCTAssertEqual(s.variableNames, [])
        XCTAssertEqual(s.rendered(with: [:]), "uptime")
    }
}

final class SnippetStoreTests: XCTestCase {
    func testUpsertGetDeleteSorted() {
        let store = SnippetStore(path: nil)
        let restart = Snippet(name: "restart", template: "docker compose restart {{service}}")
        let logs = Snippet(name: "Logs", template: "docker compose logs -f {{service}}")
        store.upsert(restart)
        store.upsert(logs)

        XCTAssertEqual(store.all().map(\.name), ["Logs", "restart"])  // skiftlägesokänslig sort
        XCTAssertEqual(store.get(restart.id)?.template, "docker compose restart {{service}}")

        store.delete(logs.id)
        XCTAssertEqual(store.all().map(\.name), ["restart"])
    }

    func testPersistAcrossInstances() throws {
        let dir = NSTemporaryDirectory() + "bastion-snippets-\(ProcessInfo.processInfo.processIdentifier)"
        let path = dir + "/snippets.json"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let s = Snippet(name: "restart", template: "docker compose restart {{service}}")
        var stored: Snippet?
        do {
            let s1 = SnippetStore(path: path)
            s1.upsert(s)
            stored = s1.get(s.id)
        }
        let s2 = SnippetStore(path: path)
        XCTAssertEqual(s2.get(s.id), stored)
    }
}
