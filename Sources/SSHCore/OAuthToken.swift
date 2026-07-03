import Foundation

/// Rått svar från en token-endpoint (authorization_code eller refresh_token-grant).
/// Ren Foundation-logik, plattformsoberoende — det interaktiva inloggningsflödet
/// (`ASWebAuthenticationSession`) och Keychain-lagringen ligger i `App/`.
public struct OAuthTokenResponse: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }

    public init(accessToken: String, refreshToken: String?, expiresIn: Double?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
    }
}

/// Det som faktiskt sparas i Keychain — absolut utgångstid i stället för
/// leverantörens relativa `expires_in`, så vi slipper räkna om vid varje läsning.
public struct StoredOAuthToken: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?

    /// `nil` utgångstid (leverantören svarade utan `expires_in`) tolkas som
    /// "fortfarande giltig" — ett 401 vid faktisk användning får trigga förnyelse.
    public var isExpired: Bool { isExpired(asOf: Date()) }

    public func isExpired(asOf now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    public init(response: OAuthTokenResponse, previousRefreshToken: String? = nil, now: Date = Date()) {
        self.accessToken = response.accessToken
        self.refreshToken = response.refreshToken ?? previousRefreshToken
        // 60 s marginal så vi förnyar strax innan utgång, inte precis vid den.
        self.expiresAt = response.expiresIn.map { now.addingTimeInterval($0 - 60) }
    }
}
