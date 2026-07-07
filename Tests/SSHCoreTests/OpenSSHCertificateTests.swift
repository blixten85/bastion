import XCTest
@testable import SSHCore

/// Testcertifikaten är RIKTIGA — genererade med `ssh-keygen -s` (en egen
/// CA-nyckel + `ssh-keygen -s ca_key -I ... -n ... -V ...`), inte
/// handskrivna/gissade. Förväntade värden (principals, key id, giltighets-
/// tider, critical options) är hämtade från `ssh-keygen -L`s egen tolkning
/// av samma certifikat OCH dubbelkollade genom att avkoda den råa
/// certifikat-blobben byte-för-byte med ett fristående Python-skript —
/// två oberoende körbara källor, inte bara läst ur specen.
final class OpenSSHCertificateTests: XCTestCase {
    /// `ssh-keygen -s ca_key -I "test-identity" -n "myuser,otheruser" -V +52w
    /// -O force-command="echo hi" user_key.pub`. `ssh-keygen -L` bekräftade:
    /// Key ID "test-identity", Serial 0, Principals myuser/otheruser,
    /// Critical Options: force-command "echo hi".
    private let userCertLine = """
    ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29tAAAAIOkcqNVIHdSSHTWvFqOKoBgUltMQnysYQ5CB0OKovB+GAAAAIBulv6ni8ICbW9lIUPcItQv4U8y9ViJnNl24fwVkvxWxAAAAAAAAAAAAAAABAAAADXRlc3QtaWRlbnRpdHkAAAAXAAAABm15dXNlcgAAAAlvdGhlcnVzZXIAAAAAakxMDAAAAABsLC5KAAAAIAAAAA1mb3JjZS1jb21tYW5kAAAACwAAAAdlY2hvIGhpAAAAggAAABVwZXJtaXQtWDExLWZvcndhcmRpbmcAAAAAAAAAF3Blcm1pdC1hZ2VudC1mb3J3YXJkaW5nAAAAAAAAABZwZXJtaXQtcG9ydC1mb3J3YXJkaW5nAAAAAAAAAApwZXJtaXQtcHR5AAAAAAAAAA5wZXJtaXQtdXNlci1yYwAAAAAAAAAAAAAAMwAAAAtzc2gtZWQyNTUxOQAAACAvS5Qbjt5MTQl3+ubCAZg4wFFeLcyL/5RSMfMYgJrtuAAAAFMAAAALc3NoLWVkMjU1MTkAAABAMiIInXPfmrmp4eXDvIK/U3njb0G9OsoYBV86PtshRxGFTQAWchUJy5XRIB6A01elUSAh11xuJ+wQcckh2x57AQ== test-user
    """

    /// `ssh-keygen -s ca_key -I "host-identity" -h -n "myhost.example.com"
    /// user_key.pub` (ingen `-V`, alltså obegränsad giltighetstid).
    /// `ssh-keygen -L` bekräftade: host certificate, "valid forever",
    /// Critical Options/Extensions: (none).
    private let hostCertLine = """
    ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29tAAAAIOmCQkLkES45q75gynLpLlORnvcPrxMEcQDc+CWkpDKwAAAAIBulv6ni8ICbW9lIUPcItQv4U8y9ViJnNl24fwVkvxWxAAAAAAAAAAAAAAACAAAADWhvc3QtaWRlbnRpdHkAAAAWAAAAEm15aG9zdC5leGFtcGxlLmNvbQAAAAAAAAAA//////////8AAAAAAAAAAAAAAAAAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIC9LlBuO3kxNCXf65sIBmDjAUV4tzIv/lFIx8xiAmu24AAAAUwAAAAtzc2gtZWQyNTUxOQAAAEB1Yk2yDXwVS9PfpX9aJcUUwrR0cPWYhrUdPb2cWyc8n7SI59RMfMFNa0ovgU9EQruyjIua5fnorKjYSjKlCJ8K test-user
    """

    /// Rå CA-publiknyckelblob (`ca_key.pub`, `ssh-ed25519 AAAA...`), avkodad
    /// för att jämföras mot certifikatens `signatureKeyBlob`.
    private let caKeyBlobHex = "0000000b7373682d65643235353139000000202f4b941b8ede4c4d0977fae6c2019838c0515e2dcc8bff945231f318809aedb8"

    func testParsesUserCertificateFields() throws {
        let cert = try OpenSSHCertificate.parse(userCertLine)
        XCTAssertEqual(cert.type, .user)
        XCTAssertEqual(cert.serial, 0)
        XCTAssertEqual(cert.keyID, "test-identity")
        XCTAssertEqual(cert.validPrincipals, ["myuser", "otheruser"])
        XCTAssertEqual(cert.publicKey.count, 32)
        XCTAssertEqual(cert.nonce.count, 32)
    }

    func testValidAfterBeforeMatchSSHKeygenOutput() throws {
        let cert = try OpenSSHCertificate.parse(userCertLine)
        // Från Python-avkodningen: valid after 1783385100, valid before 1814834762.
        XCTAssertEqual(cert.validAfter.timeIntervalSince1970, 1_783_385_100)
        XCTAssertEqual(cert.validBefore.timeIntervalSince1970, 1_814_834_762)
    }

    func testCriticalOptionForceCommandDecodesNestedString() throws {
        let cert = try OpenSSHCertificate.parse(userCertLine)
        XCTAssertEqual(cert.criticalOptions.count, 1)
        XCTAssertEqual(cert.criticalOptions[0].name, "force-command")
        XCTAssertEqual(cert.criticalOptions[0].decodedString, "echo hi")
    }

    func testExtensionNamesMatchSSHKeygenOutput() throws {
        let cert = try OpenSSHCertificate.parse(userCertLine)
        XCTAssertEqual(
            Set(cert.extensionNames),
            Set(["permit-X11-forwarding", "permit-agent-forwarding",
                 "permit-port-forwarding", "permit-pty", "permit-user-rc"]))
    }

    func testSignatureKeyBlobMatchesRealCAPublicKey() throws {
        let cert = try OpenSSHCertificate.parse(userCertLine)
        let expected = Data(hexString: caKeyBlobHex)!
        XCTAssertEqual(cert.signatureKeyBlob, expected)
    }

    func testSignatureBlobIsNonEmpty() throws {
        // Ren parsning verifierar INTE signaturen (se doc-kommentar på
        // OpenSSHCertificate) — bara att fältet finns och har rimligt
        // innehåll (en Ed25519-signatur är 64 byte + typsträngen).
        let cert = try OpenSSHCertificate.parse(userCertLine)
        XCTAssertGreaterThan(cert.signatureBlob.count, 64)
    }

    func testHostCertificateType() throws {
        let cert = try OpenSSHCertificate.parse(hostCertLine)
        XCTAssertEqual(cert.type, .host)
        XCTAssertEqual(cert.validPrincipals, ["myhost.example.com"])
        XCTAssertTrue(cert.criticalOptions.isEmpty)
        XCTAssertTrue(cert.extensionNames.isEmpty)
    }

    /// "Giltig för alltid" (ingen `-V` gavs) kodas som validAfter=0,
    /// validBefore=UInt64.max — bekräftat genom att avkoda den råa
    /// certifikat-blobben (`0xffffffffffffffff`), inte bara antaget.
    func testForeverValidityUsesSentinelTimestamps() throws {
        let cert = try OpenSSHCertificate.parse(hostCertLine)
        XCTAssertEqual(cert.validAfter.timeIntervalSince1970, 0)
        XCTAssertEqual(cert.validBefore.timeIntervalSince1970, Double(UInt64.max))
    }

    func testUnsupportedCertTypeMagicThrows() {
        // "ssh-rsa-cert-v01@openssh.com" — en annan nyckeltyps certifikat,
        // som denna kodbas (bara Ed25519, se SSHKeyError.unsupportedKeyType)
        // medvetet inte stödjer.
        var writer = Data()
        func writeString(_ s: String) {
            let bytes = Array(s.utf8)
            var len = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &len) { writer.append(contentsOf: $0) }
            writer.append(contentsOf: bytes)
        }
        writeString("ssh-rsa-cert-v01@openssh.com")
        let line = "ssh-rsa-cert-v01@openssh.com \(writer.base64EncodedString())"
        XCTAssertThrowsError(try OpenSSHCertificate.parse(line)) { error in
            guard case SSHKeyError.unsupportedKeyType(let t) = error else {
                return XCTFail("fel feltyp: \(error)")
            }
            XCTAssertEqual(t, "ssh-rsa-cert-v01@openssh.com")
        }
    }

    func testTruncatedBlobThrowsMalformedInsteadOfCrashing() {
        let tooShort = "ssh-ed25519-cert-v01@openssh.com " + Data([0, 0, 0, 100]).base64EncodedString()
        XCTAssertThrowsError(try OpenSSHCertificate.parse(tooShort)) { error in
            guard case SSHKeyError.malformed = error else {
                return XCTFail("fel feltyp: \(error)")
            }
        }
    }

    // MARK: - Signaturverifiering (mot samma RIKTIGA certifikat som ovan)

    /// Bevisar hela vägen mot en genuint `ssh-keygen -s`-signerad blob —
    /// verifierad genom att FAKTISKT flippa en byte i den signerade datan
    /// (inuti publicKey-fältet) och kontrollera att signaturen då korrekt
    /// underkänns, inte bara att den godkänns för det oförändrade fallet
    /// (ett buggigt "returnera alltid true" skulle annars klara det testet).
    func testVerifySignatureSucceedsForRealUserCertificate() throws {
        let cert = try OpenSSHCertificate.parse(userCertLine)
        XCTAssertTrue(try cert.verifySignature())
    }

    func testVerifySignatureSucceedsForRealHostCertificate() throws {
        let cert = try OpenSSHCertificate.parse(hostCertLine)
        XCTAssertTrue(try cert.verifySignature())
    }

    func testVerifySignatureFailsForTamperedCertificate() throws {
        let base64 = String(userCertLine.split(separator: " ")[1])
        var raw = [UInt8](Data(base64Encoded: base64)!)
        raw[80] ^= 0xFF  // inuti publicKey-fältet, väl efter magic+nonce
        let tampered = "ssh-ed25519-cert-v01@openssh.com " + Data(raw).base64EncodedString()
        let cert = try OpenSSHCertificate.parse(tampered)
        XCTAssertFalse(try cert.verifySignature())
    }

    func testVerifySignatureThrowsForUnsupportedSigningKeyType() throws {
        // Bygger en syntetisk signatureKeyBlob med typsträngen "ssh-rsa" —
        // enda delen som behöver vara syntetisk (en riktig RSA-signerande
        // testfixtur skulle kräva en separat RSA-CA, onödigt för att bevisa
        // att fel-typ-vägen faktiskt kastar rätt fel istället för att krascha
        // eller tyst godkänna).
        var cert = try OpenSSHCertificate.parse(userCertLine)
        var fakeKeyBlob = Data()
        let type = "ssh-rsa"
        fakeKeyBlob.append(contentsOf: withUnsafeBytes(of: UInt32(type.utf8.count).bigEndian, Array.init))
        fakeKeyBlob.append(contentsOf: type.utf8)
        cert = OpenSSHCertificate(
            nonce: cert.nonce, publicKey: cert.publicKey, serial: cert.serial, type: cert.type,
            keyID: cert.keyID, validPrincipals: cert.validPrincipals, validAfter: cert.validAfter,
            validBefore: cert.validBefore, criticalOptions: cert.criticalOptions,
            extensionNames: cert.extensionNames, signatureKeyBlob: fakeKeyBlob,
            signatureBlob: cert.signatureBlob, signedData: cert.signedData)
        XCTAssertThrowsError(try cert.verifySignature()) { error in
            guard case OpenSSHCertificateError.unsupportedSigningKeyType(let t) = error else {
                return XCTFail("fel feltyp: \(error)")
            }
            XCTAssertEqual(t, "ssh-rsa")
        }
    }
}

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
            i += 2
        }
        self = Data(bytes)
    }
}
