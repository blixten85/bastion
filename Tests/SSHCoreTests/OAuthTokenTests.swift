import XCTest
@testable import SSHCore

final class OAuthTokenTests: XCTestCase {
    func testNotExpiredJustAfterIssue() {
        let response = OAuthTokenResponse(accessToken: "a", refreshToken: "r", expiresIn: 3600)
        let now = Date()
        let token = StoredOAuthToken(response: response, now: now)
        XCTAssertFalse(token.isExpired)
    }

    func testExpiredPastExpiryMinusMargin() {
        let response = OAuthTokenResponse(accessToken: "a", refreshToken: "r", expiresIn: 3600)
        let issuedAt = Date(timeIntervalSince1970: 0)
        let token = StoredOAuthToken(response: response, now: issuedAt)
        // expiresAt = issuedAt + 3600 - 60 = issuedAt + 3540
        let justBefore = issuedAt.addingTimeInterval(3539)
        let justAfter = issuedAt.addingTimeInterval(3541)
        XCTAssertFalse(token.isExpired(asOf: justBefore))
        XCTAssertTrue(token.isExpired(asOf: justAfter))
    }

    func testNoExpiresInNeverExpires() {
        let response = OAuthTokenResponse(accessToken: "a", refreshToken: "r", expiresIn: nil)
        let token = StoredOAuthToken(response: response)
        XCTAssertNil(token.expiresAt)
        XCTAssertFalse(token.isExpired)
    }

    func testRefreshTokenCarriesOverWhenProviderOmitsIt() {
        // De flesta refresh_token-svar innehåller ingen ny refresh_token —
        // den gamla måste bevaras, annars tappar vi förmågan att förnya igen.
        let response = OAuthTokenResponse(accessToken: "new-access", refreshToken: nil, expiresIn: 3600)
        let token = StoredOAuthToken(response: response, previousRefreshToken: "old-refresh")
        XCTAssertEqual(token.refreshToken, "old-refresh")
        XCTAssertEqual(token.accessToken, "new-access")
    }

    func testRefreshTokenReplacedWhenProviderRotatesIt() {
        let response = OAuthTokenResponse(accessToken: "new-access", refreshToken: "rotated-refresh", expiresIn: 3600)
        let token = StoredOAuthToken(response: response, previousRefreshToken: "old-refresh")
        XCTAssertEqual(token.refreshToken, "rotated-refresh")
    }

    func testCodableRoundTrip() throws {
        let response = OAuthTokenResponse(accessToken: "a", refreshToken: "r", expiresIn: 3600)
        let token = StoredOAuthToken(response: response)
        let data = try JSONEncoder().encode(token)
        let decoded = try JSONDecoder().decode(StoredOAuthToken.self, from: data)
        XCTAssertEqual(decoded, token)
    }
}
