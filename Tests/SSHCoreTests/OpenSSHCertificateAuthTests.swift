import XCTest
import NIOCore
import NIOPosix
import NIOSSH
@testable import SSHCore

/// Testar `SSHAuth.certificate`s auth-erbjudande DIREKT (utan en full
/// nätverksrundtur) — se `SSHUserAuth.swift`s doc-kommentar på
/// `.certificate`-grenen för varför: swift-nio-ssh SERVER-rollen kan inte
/// ta emot certifikatbaserad publickey-auth (dess
/// `readUserAuthRequestMessage()` känner bara igen de fyra RÅA nyckeltyperna
/// i `NIOSSHPublicKey.knownAlgorithms`, aldrig `*-cert-v01@openssh.com`),
/// så `LoopbackServer` (som använder biblioteket i serverrollen) kan aldrig
/// genuint ACCEPTERA ett sådant erbjudande — bekräftat empiriskt genom att
/// instrumentera biblioteket temporärt, inte gissat. Detta testar istället
/// EXAKT det Bastion faktiskt kontrollerar som CLIENT: att erbjudandet
/// byggs, signeras och innehåller rätt certifikatinnehåll — sedan
/// verifieras det (offline, med samma `NIOSSHCertifiedPublicKey.validate`
/// en riktig sshd använder) för att bevisa att en KORREKT implementerad
/// server SKULLE acceptera det.
final class OpenSSHCertificateAuthTests: XCTestCase {
    private func waitForExit(_ pid: Int32) -> Int32 {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return (status >> 8) & 0xFF
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        XCTAssertEqual(waitForExit(process.processIdentifier), 0, "\(executable) \(arguments) misslyckades")
    }

    private struct Fixture {
        let userKeyPath: String
        let userCertPath: String
        let caPublicKey: NIOSSHPublicKey
    }

    /// Genererar en RIKTIG CA + användarnyckel + `ssh-keygen -s`-signerat
    /// certifikat (principal = `principal`) — inte handskrivet/gissat.
    private func makeFixture(principal: String) throws -> Fixture {
        let dir = NSTemporaryDirectory() + "bastion-cert-auth-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }

        let caKeyPath = dir + "/ca_key"
        let userKeyPath = dir + "/user_key"

        try run("/usr/bin/ssh-keygen", ["-t", "ed25519", "-f", caKeyPath, "-N", "", "-C", "test-ca"])
        try run("/usr/bin/ssh-keygen", ["-t", "ed25519", "-f", userKeyPath, "-N", "", "-C", "test-user"])
        try run("/usr/bin/ssh-keygen", [
            "-s", caKeyPath, "-I", "cert-auth-test", "-n", principal, "-V", "+1d", userKeyPath + ".pub",
        ])

        let caPubLine = try String(contentsOfFile: caKeyPath + ".pub", encoding: .utf8)
        return Fixture(
            userKeyPath: userKeyPath, userCertPath: userKeyPath + "-cert.pub",
            caPublicKey: try NIOSSHPublicKey(openSSHPublicKey: caPubLine))
    }

    /// Anropar `SSHUserAuth.nextAuthenticationType` direkt (ingen socket,
    /// inget `SSHSession`) — precis det NIOSSH självt skulle anropa, men
    /// utan att bero på att en (i det här biblioteket trasig) server tar
    /// emot resultatet.
    private func requestOffer(auth: SSHAuth, username: String = "tester") async throws -> (
        offer: NIOSSHUserAuthenticationOffer?, gaveUp: Bool
    ) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let loop = group.next()

        final class GaveUpBox: @unchecked Sendable { var value = false }
        let gaveUpBox = GaveUpBox()
        let delegate = SSHUserAuth(username: username, auth: auth, onGiveUp: { gaveUpBox.value = true })

        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .all, nextChallengePromise: promise)
        let offer = try await promise.futureResult.get()
        return (offer, gaveUpBox.value)
    }

    func testCertificateOfferIsSignedAndContainsRealCertificate() async throws {
        let fixture = try makeFixture(principal: "tester")
        let auth = try OpenSSHPrivateKey.loadCertificate(
            keyPath: fixture.userKeyPath, certPath: fixture.userCertPath)

        let (offer, gaveUp) = try await requestOffer(auth: auth)
        XCTAssertFalse(gaveUp)

        guard let offer, case .privateKey(let pk) = offer.offer else {
            return XCTFail("förväntade ett .privateKey-erbjudande")
        }
        guard let certifiedKey = NIOSSHCertifiedPublicKey(pk.publicKey) else {
            return XCTFail("erbjudandets publika nyckel är inte ett certifikat")
        }
        XCTAssertEqual(certifiedKey.type, .user)
        XCTAssertEqual(certifiedKey.validPrincipals, ["tester"])

        // Bevisar att en KORREKT implementerad server (en riktig sshd, eller
        // ett framtida swift-nio-ssh med fixad server-sida) SKULLE
        // acceptera det här — samma valideringsanrop en riktig sshd gör.
        XCTAssertNoThrow(
            try certifiedKey.validate(
                principal: "tester", type: .user, allowedAuthoritySigningKeys: [fixture.caPublicKey]))
    }

    func testCertificateOfferFailsValidationForWrongPrincipal() async throws {
        // Certifikatet gäller "otheruser", vi loggar in som "tester" — måste
        // misslyckas ÄVEN med rätt/betrodd CA. Bevisar att `validate()`
        // faktiskt kollar principalen, inte bara signaturen.
        let fixture = try makeFixture(principal: "otheruser")
        let auth = try OpenSSHPrivateKey.loadCertificate(
            keyPath: fixture.userKeyPath, certPath: fixture.userCertPath)

        let (offer, _) = try await requestOffer(auth: auth, username: "tester")
        guard let offer, case .privateKey(let pk) = offer.offer,
              let certifiedKey = NIOSSHCertifiedPublicKey(pk.publicKey)
        else {
            return XCTFail("förväntade ett giltigt certifikaterbjudande")
        }

        XCTAssertThrowsError(
            try certifiedKey.validate(
                principal: "tester", type: .user, allowedAuthoritySigningKeys: [fixture.caPublicKey]))
    }

    func testCertificateOfferFailsValidationForUntrustedCA() async throws {
        let fixture = try makeFixture(principal: "tester")
        let auth = try OpenSSHPrivateKey.loadCertificate(
            keyPath: fixture.userKeyPath, certPath: fixture.userCertPath)

        // En helt orelaterad CA — certifikatet signerades INTE av den här.
        let otherFixture = try makeFixture(principal: "tester")

        let (offer, _) = try await requestOffer(auth: auth)
        guard let offer, case .privateKey(let pk) = offer.offer,
              let certifiedKey = NIOSSHCertifiedPublicKey(pk.publicKey)
        else {
            return XCTFail("förväntade ett giltigt certifikaterbjudande")
        }

        XCTAssertThrowsError(
            try certifiedKey.validate(
                principal: "tester", type: .user, allowedAuthoritySigningKeys: [otherFixture.caPublicKey]))
    }

    func testCertificateAuthGivesUpWhenServerDoesNotSupportPublicKey() async throws {
        let fixture = try makeFixture(principal: "tester")
        let auth = try OpenSSHPrivateKey.loadCertificate(
            keyPath: fixture.userKeyPath, certPath: fixture.userCertPath)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let loop = group.next()

        final class GaveUpBox: @unchecked Sendable { var value = false }
        let gaveUpBox = GaveUpBox()
        let delegate = SSHUserAuth(username: "tester", auth: auth, onGiveUp: { gaveUpBox.value = true })

        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: [.password], nextChallengePromise: promise)
        let offer = try await promise.futureResult.get()

        XCTAssertNil(offer)
        XCTAssertTrue(gaveUpBox.value)
    }
}
