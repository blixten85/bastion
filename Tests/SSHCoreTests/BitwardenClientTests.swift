import XCTest
@testable import SSHCore

#if !os(iOS)
final class BitwardenClientTests: XCTestCase {
    /// Skriver ett riktigt, körbart `/bin/sh`-skript — samma mönster som
    /// `TailscaleStatusTests.makeScript`, en verklig kortlivad process
    /// istället för en mockad `bw`.
    private func makeScript(_ body: String) throws -> URL {
        let path = NSTemporaryDirectory() + "bw-fixture-\(UUID().uuidString).sh"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return URL(fileURLWithPath: path)
    }

    func testFetchPasswordStripsTrailingNewline() async throws {
        let script = try makeScript("#!/bin/sh\nprintf 'hunter2\\n'\n")
        let password = try await withTimeout(seconds: 10) {
            try BitwardenClient.fetchPassword(itemID: "irrelevant", session: nil, executableURL: script, binaryName: "")
        }
        XCTAssertEqual(password, "hunter2")
    }

    /// Ledande/inre whitespace i ett RIKTIGT lösenord får INTE trimmas bort —
    /// samma lärdom som PR #173 (trimning korrumperade giltiga lösenord).
    func testFetchPasswordPreservesInnerWhitespaceAndLeadingSpace() async throws {
        let script = try makeScript("#!/bin/sh\nprintf ' a b \\n'\n")
        let password = try await withTimeout(seconds: 10) {
            try BitwardenClient.fetchPassword(itemID: "irrelevant", session: nil, executableURL: script, binaryName: "")
        }
        XCTAssertEqual(password, " a b ")
    }

    func testFetchPasswordPassesSessionViaEnvironment() async throws {
        // Ekar BW_SESSION-miljövariabeln så testet kan verifiera att sessionen
        // skickas som miljö (INTE som argv `--session`, som läcker via `/proc/*/cmdline`).
        let script = try makeScript("#!/bin/sh\necho \"$BW_SESSION\"\n")
        let password = try await withTimeout(seconds: 10) {
            try BitwardenClient.fetchPassword(itemID: "my-item", session: "tok123", executableURL: script, binaryName: "")
        }
        XCTAssertEqual(password, "tok123")
    }

    /// Regressionsskydd för `--nointeraction`: utan flaggan hade `bw` kunnat
    /// hänga och vänta på ett interaktivt huvudlösenords-prompt (Bastion har
    /// ingen terminal att fråga i) i stället för att faila direkt — se
    /// cubic-fyndet på PR #185 om att detta saknade testtäckning.
    func testFetchPasswordPassesNointeractionFlag() async throws {
        let script = try makeScript("#!/bin/sh\necho \"$@\"\n")
        let output = try await withTimeout(seconds: 10) {
            try BitwardenClient.fetchPassword(itemID: "my-item", session: nil, executableURL: script, binaryName: "")
        }
        XCTAssertTrue(output.contains("--nointeraction"), "argv saknade --nointeraction: \(output)")
    }

    func testFetchPasswordThrowsOnNonZeroExit() async throws {
        let script = try makeScript("#!/bin/sh\necho 'Vault is locked.' >&2\nexit 1\n")
        do {
            _ = try await withTimeout(seconds: 10) {
                try BitwardenClient.fetchPassword(itemID: "irrelevant", session: nil, executableURL: script, binaryName: "")
            }
            XCTFail("förväntade att fetchPassword skulle kasta")
        } catch let error as BitwardenClientError {
            guard case .commandFailed(let code, let stderr) = error else {
                return XCTFail("fel feltyp: \(error)")
            }
            XCTAssertEqual(code, 1)
            XCTAssertTrue(stderr.contains("Vault is locked"))
        }
    }

    func testFetchPasswordThrowsOnEmptyOutput() async throws {
        let script = try makeScript("#!/bin/sh\nprintf ''\n")
        do {
            _ = try await withTimeout(seconds: 10) {
                try BitwardenClient.fetchPassword(itemID: "irrelevant", session: nil, executableURL: script, binaryName: "")
            }
            XCTFail("förväntade att fetchPassword skulle kasta")
        } catch let error as BitwardenClientError {
            XCTAssertEqual(error, .emptyPassword)
        }
    }
}
#endif
