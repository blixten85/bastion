#if os(tvOS)
import Foundation
import SSHCore

enum OAuthError: Error {
    case notConfigured
    case notLoggedIn
    case cancelled
    case invalidCallback
    case requestFailed(String)
    case keychainWriteFailed
    case accessDenied
    case expired
}

private struct OAuthErrorBody: Decodable {
    let error: String
    let error_description: String?
}

private struct OAuthTokenRefreshError: Error {
    let message: String
    let isPermanent: Bool
}

/// tvOS-motsvarighet till `App/OAuthTokenStore.swift` — nyckeln är
/// leverantörens `id`-sträng direkt istället för hela `OAuthProviderConfig`
/// (den PKCE-baserade konfigurationstypen finns inte här, se
/// `TVDeviceFlowOAuthManager.swift` för varför: `ASWebAuthenticationSession`
/// är `API_UNAVAILABLE` på tvOS, device-flow-token-lagringen behöver bara
/// ett id att nyckla på). `OAuthTokenResponse`/`StoredOAuthToken` återanvänds
/// direkt från SSHCore (redan plattformsneutrala, delade med App/).
enum TVOAuthTokenStore {
    private static func keychainKey(_ providerID: String) -> String { "oauth-\(providerID)-token" }

    static func isLoggedIn(_ providerID: String) -> Bool {
        Keychain.get(keychainKey(providerID)) != nil
    }

    static func logout(_ providerID: String) {
        Keychain.delete(keychainKey(providerID))
    }

    static func save(_ token: StoredOAuthToken, for providerID: String) throws {
        let data = try JSONEncoder().encode(token)
        guard Keychain.set(String(decoding: data, as: UTF8.self), for: keychainKey(providerID)) else {
            throw OAuthError.keychainWriteFailed
        }
    }

    static func load(for providerID: String) -> StoredOAuthToken? {
        guard let json = Keychain.get(keychainKey(providerID)) else { return nil }
        return try? JSONDecoder().decode(StoredOAuthToken.self, from: Data(json.utf8))
    }

    /// Hämtar en giltig access token, förnyar tyst via `refresh_token` om
    /// den gått ut. Blockerande — matchar `SyncProvider`s synkrona gränssnitt.
    static func validAccessToken(for providerID: String, tokenEndpoint: URL, clientID: String) throws -> String {
        guard let token = load(for: providerID) else { throw OAuthError.notLoggedIn }
        guard token.isExpired else { return token.accessToken }
        // En utgången token UTAN refresh-token är oanvändbar — returnera den
        // ALDRIG som "giltig" (cubic P2, skulle annars skicka en känt
        // utgången bearer-token istället för att kräva ny inloggning).
        guard let refreshToken = token.refreshToken else {
            logout(providerID)
            throw OAuthError.notLoggedIn
        }
        do {
            let refreshed = try refresh(refreshToken, tokenEndpoint: tokenEndpoint, clientID: clientID)
            try save(refreshed, for: providerID)
            return refreshed.accessToken
        } catch let error as OAuthTokenRefreshError where error.isPermanent {
            // `invalid_grant` m.fl. betyder att refresh-token är permanent
            // ogiltig (återkallad/utgången) — utan detta skulle varje
            // framtida synk upprepa samma misslyckade förnyelse i all
            // oändlighet istället för att be användaren logga in igen
            // (cubic P2).
            logout(providerID)
            throw OAuthError.notLoggedIn
        }
    }

    private static func refresh(_ refreshToken: String, tokenEndpoint: URL, clientID: String) throws -> StoredOAuthToken {
        // Ett skickat `refresh_token` är en långlivad hemlighet — vägra
        // skicka den till en icke-HTTPS-endpoint (cubic, säkerhetsfynd).
        // Nuvarande anropare använder alltid hårdkodade HTTPS-endpoints,
        // men funktionen är generell nog att en framtida felkonfiguration
        // annars skulle skicka den i klartext.
        guard tokenEndpoint.scheme == "https" else {
            throw OAuthError.requestFailed("token-endpointen måste använda HTTPS")
        }
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        let (data, response) = try synchronousRequest(request)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.requestFailed("inget svar") }
        if !(200..<300).contains(http.statusCode) {
            let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data)
            let permanent = body?.error == "invalid_grant" || body?.error == "invalid_client"
            throw OAuthTokenRefreshError(message: String(decoding: data, as: UTF8.self), isPermanent: permanent)
        }
        let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        return StoredOAuthToken(response: decoded, previousRefreshToken: refreshToken)
    }

    /// `application/x-www-form-urlencoded` kräver striktare kodning än
    /// `.urlQueryAllowed` — den senare lämnar `&`/`+` okodade, vilket får en
    /// token/refresh-token som råkar innehålla dem tolkad som extra fält
    /// eller mellanslag (cubic P2). `formURLEncoded` är samma
    /// karaktärsuppsättning RFC 3986 "unreserved" tillåter, minus `+`
    /// (kodas alltid, aldrig tolkat som mellanslag av mottagaren).
    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)!
    }

    static func checkHTTPStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthError.requestFailed(String(decoding: data, as: UTF8.self))
        }
    }

    /// Blockerande HTTP-anrop, samma motivering som App/OAuthTokenStore.swift.
    static func synchronousRequest(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error>!
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(OAuthError.requestFailed("tomt svar"))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try result.get()
    }
}
#endif
