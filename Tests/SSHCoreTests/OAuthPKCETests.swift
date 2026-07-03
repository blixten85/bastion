import XCTest
@testable import SSHCore

final class OAuthPKCETests: XCTestCase {
    // Känd testvektor ur RFC 7636 §4.1/§4.2 (S256).
    func testChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(OAuthPKCE.challenge(forVerifier: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierIsURLSafeAndRightLength() {
        for _ in 0..<20 {
            let v = OAuthPKCE.makeVerifier()
            XCTAssertEqual(v.count, 43) // 32 råa byte -> 43 base64url-tecken utan padding
            XCTAssertTrue(v.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            XCTAssertFalse(v.contains("+")); XCTAssertFalse(v.contains("/")); XCTAssertFalse(v.contains("="))
        }
    }

    func testVerifiersAreNotReused() {
        let a = OAuthPKCE.makeVerifier()
        let b = OAuthPKCE.makeVerifier()
        XCTAssertNotEqual(a, b)
    }

    func testChallengeIsDeterministicForSameVerifier() {
        let v = OAuthPKCE.makeVerifier()
        XCTAssertEqual(OAuthPKCE.challenge(forVerifier: v), OAuthPKCE.challenge(forVerifier: v))
    }
}
