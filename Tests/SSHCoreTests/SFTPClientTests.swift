import XCTest
@testable import SSHCore

final class SFTPClientTests: XCTestCase {
    private func connectedSession(_ server: LoopbackServer) async throws -> SSHSession {
        let session = SSHSession(
            target: SSHTarget(host: "127.0.0.1", port: server.port, username: "tester"),
            auth: .password("hunter2"), knownHosts: KnownHosts(path: nil))
        try await session.connect()
        return session
    }

    func testRealpathResolvesRelativeToRoot() async throws {
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }
        let session = try await connectedSession(server)
        let sftp = try await SFTPClient.open(on: session)

        let resolved = try await sftp.realpath("some/path")
        XCTAssertEqual(resolved, "/some/path")

        await sftp.close()
        await session.close()
    }

    func testWriteThenReadFileRoundTrips() async throws {
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }
        let session = try await connectedSession(server)
        let sftp = try await SFTPClient.open(on: session)

        let content = Array("hej från Bastion — åäö\n".utf8)
        try await sftp.writeFile("test.txt", data: content)
        let readBack = try await sftp.readFile("test.txt")
        XCTAssertEqual(readBack, content)

        await sftp.close()
        await session.close()
    }

    func testWriteFileLargerThanOneChunk() async throws {
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }
        let session = try await connectedSession(server)
        let sftp = try await SFTPClient.open(on: session)

        // Tre gånger chunkSize -> minst tre READ/WRITE-rundor krävs.
        let content = (0..<200_000).map { UInt8($0 % 256) }
        try await sftp.writeFile("big.bin", data: content, chunkSize: 32768)
        let readBack = try await sftp.readFile("big.bin", chunkSize: 32768)
        XCTAssertEqual(readBack, content)

        await sftp.close()
        await session.close()
    }

    func testListDirectoryFindsWrittenFiles() async throws {
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }
        let session = try await connectedSession(server)
        let sftp = try await SFTPClient.open(on: session)

        try await sftp.writeFile("a.txt", data: Array("a".utf8))
        try await sftp.writeFile("b.txt", data: Array("b".utf8))
        let entries = try await sftp.listDirectory(".")

        XCTAssertEqual(Set(entries.map(\.filename)), ["a.txt", "b.txt"])
        XCTAssertTrue(entries.allSatisfy { $0.attributes.size != nil })

        await sftp.close()
        await session.close()
    }

    func testMkdirRmdirRoundTrip() async throws {
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }
        let session = try await connectedSession(server)
        let sftp = try await SFTPClient.open(on: session)

        try await sftp.mkdir("subdir")
        let entries = try await sftp.listDirectory(".")
        XCTAssertTrue(entries.contains { $0.filename == "subdir" })

        try await sftp.rmdir("subdir")
        let afterRemoval = try await sftp.listDirectory(".")
        XCTAssertFalse(afterRemoval.contains { $0.filename == "subdir" })

        await sftp.close()
        await session.close()
    }

    func testRemoveDeletesFile() async throws {
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }
        let session = try await connectedSession(server)
        let sftp = try await SFTPClient.open(on: session)

        try await sftp.writeFile("gone.txt", data: Array("x".utf8))
        try await sftp.remove("gone.txt")
        let entries = try await sftp.listDirectory(".")
        XCTAssertFalse(entries.contains { $0.filename == "gone.txt" })

        await sftp.close()
        await session.close()
    }

    func testRenameMovesFile() async throws {
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }
        let session = try await connectedSession(server)
        let sftp = try await SFTPClient.open(on: session)

        try await sftp.writeFile("old.txt", data: Array("hej".utf8))
        try await sftp.rename("old.txt", to: "new.txt")
        let entries = try await sftp.listDirectory(".")
        XCTAssertFalse(entries.contains { $0.filename == "old.txt" })
        XCTAssertTrue(entries.contains { $0.filename == "new.txt" })
        let renamed = try await sftp.readFile("new.txt")
        XCTAssertEqual(renamed, Array("hej".utf8))

        await sftp.close()
        await session.close()
    }

    func testStatReturnsFileSize() async throws {
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }
        let session = try await connectedSession(server)
        let sftp = try await SFTPClient.open(on: session)

        try await sftp.writeFile("sized.txt", data: Array(repeating: 0x41, count: 777))
        let attrs = try await sftp.stat("sized.txt")
        XCTAssertEqual(attrs.size, 777)

        await sftp.close()
        await session.close()
    }

    func testReadingMissingFileThrowsNoSuchFile() async throws {
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }
        let session = try await connectedSession(server)
        let sftp = try await SFTPClient.open(on: session)

        do {
            _ = try await sftp.readFile("does-not-exist.txt")
            XCTFail("skulle ha kastat")
        } catch let error as SFTPStatusError {
            XCTAssertEqual(error.code, .noSuchFile)
        }

        await sftp.close()
        await session.close()
    }

    func testConcurrentRequestsOnSameConnectionAreMatchedByID() async throws {
        // Flera samtidiga anrop över samma SFTP-kanal ska matchas rätt via
        // SFTP:s eget id-fält, inte råka blanda ihop svar (aktören
        // serialiserar pending-tabellen, men själva förfrågningarna skickas
        // koncurrent här för att bevisa att inget kapplöpningstillstånd
        // uppstår i id-tilldelningen/dispatchen).
        let server = try LoopbackServer.start(password: "hunter2")
        defer { server.shutdown() }
        let session = try await connectedSession(server)
        let sftp = try await SFTPClient.open(on: session)

        for i in 0..<10 {
            try await sftp.writeFile("file\(i).txt", data: Array("innehåll \(i)".utf8))
        }

        try await withThrowingTaskGroup(of: (Int, [UInt8]).self) { group in
            for i in 0..<10 {
                group.addTask {
                    let data = try await sftp.readFile("file\(i).txt")
                    return (i, data)
                }
            }
            for try await (i, data) in group {
                XCTAssertEqual(data, Array("innehåll \(i)".utf8))
            }
        }

        await sftp.close()
        await session.close()
    }
}
