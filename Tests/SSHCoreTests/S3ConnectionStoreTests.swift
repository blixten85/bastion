import XCTest
@testable import SSHCore

final class S3ConnectionStoreTests: XCTestCase {
    private func makeConnection(name: String, accessKeyID: String = "AKID") -> S3Connection {
        S3Connection(
            name: name, endpoint: "https://s3.hostup.se", region: "us-east-1",
            accessKeyID: accessKeyID, secretAccessKey: "secret")
    }

    func testUpsertGetDeleteSorted() {
        let store = S3ConnectionStore(path: nil)
        let a = makeConnection(name: "Hostup")
        let b = makeConnection(name: "annat-konto")
        store.upsert(a)
        store.upsert(b)

        XCTAssertEqual(store.all().map(\.name), ["annat-konto", "Hostup"])  // skiftlägesokänslig sort
        XCTAssertEqual(store.get(a.id)?.accessKeyID, "AKID")

        store.delete(b.id)
        XCTAssertEqual(store.all().map(\.name), ["Hostup"])
    }

    func testPersistAcrossInstances() throws {
        let dir = NSTemporaryDirectory() + "bastion-s3conn-\(ProcessInfo.processInfo.processIdentifier)"
        let path = dir + "/s3connections.json"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let connection = makeConnection(name: "Hostup")
        var stored: S3Connection?
        do {
            let s1 = S3ConnectionStore(path: path)
            s1.upsert(connection)
            stored = s1.get(connection.id)
        }
        let s2 = S3ConnectionStore(path: path)
        XCTAssertEqual(s2.get(connection.id), stored)
    }

    func testEndpointURLParsesValidString() {
        let connection = makeConnection(name: "x")
        XCTAssertEqual(connection.endpointURL?.host, "s3.hostup.se")
    }

    func testCredentialsMatchStoredKeys() {
        let connection = makeConnection(name: "x", accessKeyID: "MYKEY")
        XCTAssertEqual(connection.credentials.accessKeyID, "MYKEY")
        XCTAssertEqual(connection.credentials.secretAccessKey, "secret")
    }
}
