import XCTest
@testable import SSHCore

private typealias Host = SSHCore.Host   // undvik krock med Foundation.Host

final class HostStoreTests: XCTestCase {
    func testUpsertGetDeleteSorted() {
        let store = HostStore(path: nil)
        let web = Host(alias: "web", hostName: "10.0.0.5", user: "deploy", tags: ["prod"])
        let nas = Host(alias: "NAS", hostName: "10.0.0.2", user: "root", tags: ["homelab"])
        store.upsert(web)
        store.upsert(nas)

        XCTAssertEqual(store.all().map { $0.alias }, ["NAS", "web"])  // skiftlägesokänslig sort
        XCTAssertEqual(store.get(web.id)?.hostName, "10.0.0.5")

        var edited = web
        edited.port = 2222
        store.upsert(edited)
        XCTAssertEqual(store.get(web.id)?.port, 2222)
        XCTAssertEqual(store.all().count, 2)  // upsert på samma id ersätter, inte dubblerar

        store.delete(nas.id)
        XCTAssertEqual(store.all().map { $0.alias }, ["web"])
    }

    func testTagFiltering() {
        let store = HostStore(path: nil)
        store.upsert(Host(alias: "a", hostName: "h1", user: "u", tags: ["prod", "web"]))
        store.upsert(Host(alias: "b", hostName: "h2", user: "u", tags: ["homelab"]))
        store.upsert(Host(alias: "c", hostName: "h3", user: "u", tags: ["prod"]))

        XCTAssertEqual(store.hosts(withTag: "prod").map { $0.alias }, ["a", "c"])
        XCTAssertEqual(store.allTags(), ["homelab", "prod", "web"])
    }

    func testPersistAcrossInstances() throws {
        let dir = NSTemporaryDirectory() + "bastion-hosts-\(ProcessInfo.processInfo.processIdentifier)"
        let path = dir + "/hosts.json"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let h = Host(alias: "srv", hostName: "1.2.3.4", user: "admin", port: 2200,
                     tags: ["x"], auth: .keyFile("/home/u/.ssh/k"))
        var stored: Host?
        do {
            let s1 = HostStore(path: path)
            s1.upsert(h)
            stored = s1.get(h.id)   // upsert stämplar om modifiedAt
        }
        let s2 = HostStore(path: path)
        let loaded = s2.get(h.id)
        XCTAssertEqual(loaded, stored)                // full round-trip inkl. auth + tidsstämpel
        XCTAssertEqual(loaded?.target.port, 2200)
    }
}
