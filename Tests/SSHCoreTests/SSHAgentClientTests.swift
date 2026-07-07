import Crypto
import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import SSHCore

/// Testerna startar en RIKTIG `ssh-agent`-process (inte en fejkad testserver
/// som `LoopbackServer` — här finns inget SSH-protokoll inblandat, bara det
/// egna agent-protokollet direkt över ett Unix-socket, så det finns inget
/// att bygga en egen server-sida för) och lägger till en riktig nyckel med
/// `ssh-add`, precis som en användare skulle. Signaturen som agenten
/// returnerar verifieras kryptografiskt (Curve25519) mot den riktiga
/// publika nyckeln — inte bara att några byte kom tillbaka.
final class SSHAgentClientTests: XCTestCase {
    private struct RunningAgent {
        let socketPath: String
        let process: Process
    }

    private func startAgent() throws -> RunningAgent {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        process.arguments = ["-D", "-a", NSTemporaryDirectory() + "bastion-agent-test-\(UUID().uuidString).sock"]
        let socketPath = process.arguments![2]
        try process.run()
        // `-D` (kör i förgrunden) gör att processen inte avslutar sig själv —
        // vi behöver bara vänta tills socket-filen faktiskt existerar innan
        // vi ansluter, annars är det en kapplöpning mot agentens egen startup.
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socketPath) {
            usleep(20_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "agentens socket dök aldrig upp")
        return RunningAgent(socketPath: socketPath, process: process)
    }

    /// `Process.waitUntilExit()` visade sig hänga (upptäckt empiriskt) när
    /// en långlivad `ssh-agent -D`-processs redan är startad via samma
    /// Foundation-`Process`-bokföring i samma testprocess — trots att
    /// `KeyManagementTests.swift` använder exakt samma `waitUntilExit()`-
    /// mönster för `ssh-keygen` UTAN problem där (ingen samtidig
    /// bakgrundsdemon). En känd kategori av swift-corelibs-foundation-kvirk
    /// med barnprocess-reaping när flera `Process`-instanser lever samtidigt.
    /// Rå `waitpid(2)` istället, kringgår Foundations bokföring helt.
    private func waitForExit(_ pid: Int32) -> Int32 {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return (status >> 8) & 0xFF
    }

    private func addKey(_ keyPath: String, socketPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        process.arguments = [keyPath]
        process.environment = ["SSH_AUTH_SOCK": socketPath]
        try process.run()
        let exitCode = waitForExit(process.processIdentifier)
        XCTAssertEqual(exitCode, 0, "ssh-add misslyckades")
    }

    /// `Process.terminate()` + `Process.waitUntilExit()` hänger (upptäckt
    /// empiriskt — hela testsviten fastnade i timmar innan det spårades hit)
    /// för just den här sortens process (`ssh-agent -D`, en förgrundsdemon
    /// vi själva startat via Foundations `Process`) på Linux, trots att en
    /// vanlig SIGTERM via `kill(2)` fungerar perfekt utanför Foundation
    /// (verifierat separat mot en shell-bakgrundad `ssh-agent`). En känd
    /// kategori av swift-corelibs-foundation-kvirk med processreaping.
    /// Kringgår hela Foundation-API:t: rå `kill(2)` + en avgränsad
    /// pollningsloop (`kill(pid, 0)` för att kolla liv) istället för
    /// `waitUntilExit()`.
    private func stopAgent(_ agent: RunningAgent) {
        let pid = agent.process.processIdentifier
        kill(pid, SIGTERM)
        for _ in 0..<50 where kill(pid, 0) == 0 {
            usleep(20_000)
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(atPath: agent.socketPath)
    }

    func testRequestIdentitiesAndSignRoundTripAgainstRealAgent() async throws {
        let agent = try startAgent()
        defer { stopAgent(agent) }

        let dir = NSTemporaryDirectory() + "bastion-agent-key-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let keyPath = dir + "/id_ed25519"

        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-t", "ed25519", "-f", keyPath, "-N", "", "-C", "agent-test"]
        try keygen.run()
        XCTAssertEqual(waitForExit(keygen.processIdentifier), 0)

        try addKey(keyPath, socketPath: agent.socketPath)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await SSHAgentClient.connect(socketPath: agent.socketPath, group: group)

        let identities = try await client.requestIdentities()
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities[0].comment, "agent-test")

        // Jämför nyckelblobben mot den RIKTIGA publika nyckelfilen ssh-keygen
        // skrev — inte bara att den finns, utan att den är byte-för-byte
        // samma SSH-wire-encoding.
        let pubLine = try String(contentsOfFile: keyPath + ".pub", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base64Part = pubLine.split(separator: " ")[1]
        let expectedBlob = Data(base64Encoded: String(base64Part))!
        XCTAssertEqual(identities[0].keyBlob, expectedBlob)

        let message = Array("hello from bastion".utf8)
        let signatureBlob = try await client.sign(keyBlob: identities[0].keyBlob, data: Data(message))

        // Signaturblobben är (RFC8709): string "ssh-ed25519" + string <64-byte signatur>.
        var reader = ByteBuffer(data: signatureBlob)
        let sigTypeLen = reader.readInteger(as: UInt32.self)!
        let sigType = String(decoding: reader.readBytes(length: Int(sigTypeLen))!, as: UTF8.self)
        XCTAssertEqual(sigType, "ssh-ed25519")
        let sigLen = reader.readInteger(as: UInt32.self)!
        let rawSignature = Data(reader.readBytes(length: Int(sigLen))!)
        XCTAssertEqual(rawSignature.count, 64)

        // Nyckelblobben är: string "ssh-ed25519" + string <32-byte publik nyckel>.
        var keyReader = ByteBuffer(data: identities[0].keyBlob)
        let keyTypeLen = keyReader.readInteger(as: UInt32.self)!
        _ = keyReader.readBytes(length: Int(keyTypeLen))
        let keyLen = keyReader.readInteger(as: UInt32.self)!
        let rawPublicKey = Data(keyReader.readBytes(length: Int(keyLen))!)

        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)
        XCTAssertTrue(publicKey.isValidSignature(rawSignature, for: Data(message)))

        await client.close()
        try? await group.shutdownGracefully()
    }

    func testSignWithUnknownKeyBlobFails() async throws {
        let agent = try startAgent()
        defer { stopAgent(agent) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await SSHAgentClient.connect(socketPath: agent.socketPath, group: group)

        // Ingen nyckel tillagd i agenten alls — vilken keyBlob som helst
        // (matchande formatet men okänd för agenten) ska ge SSH_AGENT_FAILURE.
        let fakeBlob = "ssh-ed25519"
        var buf = ByteBuffer()
        buf.writeInteger(UInt32(fakeBlob.utf8.count))
        buf.writeBytes(Array(fakeBlob.utf8))
        buf.writeInteger(UInt32(32))
        buf.writeBytes([UInt8](repeating: 0, count: 32))

        do {
            _ = try await client.sign(keyBlob: Data(buf.readableBytesView), data: Data("x".utf8))
            XCTFail("skulle ha misslyckats — okänd nyckel")
        } catch SSHAgentError.agentFailure {
            // förväntat
        }
        await client.close()
        try? await group.shutdownGracefully()
    }

    func testEmptyAgentReturnsNoIdentities() async throws {
        let agent = try startAgent()
        defer { stopAgent(agent) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = try await SSHAgentClient.connect(socketPath: agent.socketPath, group: group)
        let identities = try await client.requestIdentities()
        XCTAssertTrue(identities.isEmpty)
        await client.close()
        try? await group.shutdownGracefully()
    }
}
