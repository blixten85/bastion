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

    func testFavoriteAndColorTagRoundTrip() throws {
        var h = Host(alias: "prod-db", hostName: "10.0.0.9", user: "admin")
        h.isFavorite = true
        h.colorTag = "red"
        let data = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(Host.self, from: data)
        XCTAssertEqual(decoded.isFavorite, true)
        XCTAssertEqual(decoded.colorTag, "red")
    }

    /// Gammal host.json (sparad innan isFavorite/colorTag fanns) ska fortfarande
    /// gå att läsa in — nycklarna saknas helt, avkodningen faller tillbaka på
    /// stored-property-defaults (false/nil) istället för att kasta.
    func testDecodesOldHostWithoutFavoriteOrColorFields() throws {
        let h = Host(alias: "legacy", hostName: "10.0.0.1", user: "root")
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(h)) as! [String: Any]
        obj.removeValue(forKey: "isFavorite")
        obj.removeValue(forKey: "colorTag")
        let oldStyleData = try JSONSerialization.data(withJSONObject: obj)

        let decoded = try JSONDecoder().decode(Host.self, from: oldStyleData)
        XCTAssertEqual(decoded.isFavorite, false)
        XCTAssertNil(decoded.colorTag)
        XCTAssertEqual(decoded.alias, "legacy")
    }

    func testPlatformRoundTrip() throws {
        var h = Host(alias: "win-vps", hostName: "10.0.0.9", user: "Administrator")
        h.platform = .windowsAdmin
        let data = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(Host.self, from: data)
        XCTAssertEqual(decoded.platform, .windowsAdmin)
    }

    /// Samma bakåtkompatibilitetsresonemang som favorit/färg-testet ovan —
    /// `platform` tillkom ännu senare, så en host.json från innan DET fältet
    /// fanns (men EFTER isFavorite/colorTag) måste också gå att läsa.
    func testDecodesOldHostWithoutPlatformField() throws {
        let h = Host(alias: "legacy2", hostName: "10.0.0.1", user: "root")
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(h)) as! [String: Any]
        obj.removeValue(forKey: "platform")
        let oldStyleData = try JSONSerialization.data(withJSONObject: obj)

        let decoded = try JSONDecoder().decode(Host.self, from: oldStyleData)
        XCTAssertEqual(decoded.platform, .posix)
    }

    func testStartupCommandRoundTrip() throws {
        var h = Host(alias: "web", hostName: "10.0.0.9", user: "deploy")
        h.startupCommand = "cd /srv/app && tmux attach || tmux new"
        let data = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(Host.self, from: data)
        XCTAssertEqual(decoded.startupCommand, "cd /srv/app && tmux attach || tmux new")
    }

    /// Samma bakåtkompatibilitetsresonemang som ovan — `startupCommand`
    /// tillkom ännu senare, så en host.json från innan DET fältet fanns
    /// måste också gå att läsa.
    func testDecodesOldHostWithoutStartupCommandField() throws {
        let h = Host(alias: "legacy3", hostName: "10.0.0.1", user: "root")
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(h)) as! [String: Any]
        obj.removeValue(forKey: "startupCommand")
        let oldStyleData = try JSONSerialization.data(withJSONObject: obj)

        let decoded = try JSONDecoder().decode(Host.self, from: oldStyleData)
        XCTAssertNil(decoded.startupCommand)
    }

    func testJumpHostIDRoundTrip() throws {
        let jump = Host(alias: "bastion-host", hostName: "10.0.0.1", user: "jump")
        var target = Host(alias: "internal-db", hostName: "10.0.1.5", user: "admin")
        target.jumpHostID = jump.id
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(Host.self, from: data)
        XCTAssertEqual(decoded.jumpHostID, jump.id)
    }

    /// Samma bakåtkompatibilitetsresonemang som ovan — `jumpHostID` tillkom
    /// ännu senare, så en host.json från innan DET fältet fanns måste också
    /// gå att läsa (utan jump host, precis som innan fältet fanns).
    func testDecodesOldHostWithoutJumpHostIDField() throws {
        let h = Host(alias: "legacy4", hostName: "10.0.0.1", user: "root")
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(h)) as! [String: Any]
        obj.removeValue(forKey: "jumpHostID")
        let oldStyleData = try JSONSerialization.data(withJSONObject: obj)

        let decoded = try JSONDecoder().decode(Host.self, from: oldStyleData)
        XCTAssertNil(decoded.jumpHostID)
    }

    func testMacAddressRoundTrip() throws {
        var host = Host(alias: "homelab", hostName: "10.0.0.9", user: "root")
        host.macAddress = "AA:BB:CC:DD:EE:FF"
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(Host.self, from: data)
        XCTAssertEqual(decoded.macAddress, "AA:BB:CC:DD:EE:FF")
    }

    /// Samma bakåtkompatibilitetsresonemang som `jumpHostID` — `macAddress`
    /// tillkom ännu senare, en host.json från innan måste gå att läsa
    /// (ingen MAC-adress, precis som innan fältet fanns).
    func testDecodesOldHostWithoutMacAddressField() throws {
        let h = Host(alias: "legacy5", hostName: "10.0.0.1", user: "root")
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(h)) as! [String: Any]
        obj.removeValue(forKey: "macAddress")
        let oldStyleData = try JSONSerialization.data(withJSONObject: obj)

        let decoded = try JSONDecoder().decode(Host.self, from: oldStyleData)
        XCTAssertNil(decoded.macAddress)
    }
}
