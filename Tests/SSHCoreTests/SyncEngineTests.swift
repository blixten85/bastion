import XCTest
@testable import SSHCore

private typealias Host = SSHCore.Host   // undvik krock med Foundation.Host

final class SyncEngineTests: XCTestCase {
    private func host(_ id: UUID, _ alias: String, at t: TimeInterval) -> Host {
        Host(id: id, alias: alias, hostName: "h", user: "u",
             modifiedAt: Date(timeIntervalSince1970: t))
    }

    func testUnionOfDistinctHosts() {
        let a = SyncState(hosts: [host(UUID(), "a", at: 1)])
        let b = SyncState(hosts: [host(UUID(), "b", at: 1)])
        let m = SyncEngine.merge(a, b)
        XCTAssertEqual(m.hosts.map { $0.alias }, ["a", "b"])
    }

    func testLastWriteWins() {
        let id = UUID()
        let a = SyncState(hosts: [host(id, "gammal", at: 100)])
        let b = SyncState(hosts: [host(id, "ny", at: 200)])
        XCTAssertEqual(SyncEngine.merge(a, b).hosts.first?.alias, "ny")
        XCTAssertEqual(SyncEngine.merge(b, a).hosts.first?.alias, "ny")  // ordningsoberoende
    }

    func testTombstoneDeletesAcrossDevices() {
        let id = UUID()
        // Enhet A raderade (gravsten senare än värdens ändring), enhet B har kvar den.
        let a = SyncState(tombstones: [id: Date(timeIntervalSince1970: 300)])
        let b = SyncState(hosts: [host(id, "kvar", at: 200)])
        let m = SyncEngine.merge(a, b)
        XCTAssertTrue(m.hosts.isEmpty)
        XCTAssertNotNil(m.tombstones[id])
    }

    func testNewerEditRevivesOverOlderDelete() {
        let id = UUID()
        let a = SyncState(tombstones: [id: Date(timeIntervalSince1970: 100)])
        let b = SyncState(hosts: [host(id, "återupplivad", at: 200)])   // redigerad efter raderingen
        let m = SyncEngine.merge(a, b)
        XCTAssertEqual(m.hosts.map { $0.alias }, ["återupplivad"])
        XCTAssertNil(m.tombstones[id])
    }

    func testIdempotentAndCommutative() {
        let id1 = UUID(), id2 = UUID()
        let a = SyncState(hosts: [host(id1, "a", at: 10)], tombstones: [id2: Date(timeIntervalSince1970: 5)])
        let b = SyncState(hosts: [host(id2, "b", at: 3), host(id1, "a2", at: 20)])
        let ab = SyncEngine.merge(a, b)
        let ba = SyncEngine.merge(b, a)
        XCTAssertEqual(ab, ba)                                  // kommutativt
        XCTAssertEqual(SyncEngine.merge(ab, ab), ab)            // idempotent
        XCTAssertEqual(ab.hosts.map { $0.alias }, ["a2"])       // LWW + gravsten slår b:s äldre id2
    }

    func testStoreMergePersists() {
        let local = HostStore(path: nil)
        let shared = Host(id: UUID(), alias: "delad", hostName: "h", user: "u")
        // Fjärrenhet har en värd vi inte har.
        local.merge(SyncState(hosts: [shared]))
        XCTAssertEqual(local.get(shared.id)?.alias, "delad")
    }

    // Två enheter som synkar genom en delad mapp konvergerar — inkl. radering.
    func testTwoDevicesConvergeThroughSharedFolder() throws {
        let dir = NSTemporaryDirectory() + "bastion-sync-\(ProcessInfo.processInfo.processIdentifier)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let provider = FolderSyncProvider(path: dir + "/shared.json")
        let deviceA = HostStore(path: dir + "/a.json")
        let deviceB = HostStore(path: dir + "/b.json")

        let h = Host(id: UUID(), alias: "web", hostName: "1.1.1.1", user: "u")
        deviceA.upsert(h)
        try deviceA.sync(with: provider)                 // A skjuter upp
        try deviceB.sync(with: provider)                 // B hämtar
        XCTAssertEqual(deviceB.get(h.id)?.alias, "web")

        deviceB.delete(h.id)                             // B raderar
        try deviceB.sync(with: provider)
        try deviceA.sync(with: provider)                 // A hämtar raderingen
        XCTAssertNil(deviceA.get(h.id))
    }
}
