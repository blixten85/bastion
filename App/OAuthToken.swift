#if canImport(SwiftUI)
import Foundation

/// Rått svar från en token-endpoint (authorization_code eller refresh_token-grant).
struct OAuthTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

/// Det som faktiskt sparas i Keychain — absolut utgångstid i stället för
/// leverantörens relativa `expires_in`, så vi slipper räkna om vid varje läsning.
struct StoredOAuthToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?

    /// `nil` utgångstid (leverantören svarade utan `expires_in`) tolkas som
    /// "fortfarande giltig" — ett 401 vid faktisk användning får trigga förnyelse.
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    init(response: OAuthTokenResponse, previousRefreshToken: String? = nil) {
        self.accessToken = response.accessToken
        self.refreshToken = response.refreshToken ?? previousRefreshToken
        // 60 s marginal så vi förnyar strax innan utgång, inte precis vid den.
        self.expiresAt = response.expiresIn.map { Date().addingTimeInterval($0 - 60) }
    }
}
#endif
