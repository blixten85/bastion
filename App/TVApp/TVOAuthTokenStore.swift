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
        guard var token = load(for: providerID) else { throw OAuthError.notLoggedIn }
        if token.isExpired, let refreshToken = token.refreshToken {
            token = try refresh(refreshToken, tokenEndpoint: tokenEndpoint, clientID: clientID)
            try save(token, for: providerID)
        }
        return token.accessToken
    }

    private static func refresh(_ refreshToken: String, tokenEndpoint: URL, clientID: String) throws -> StoredOAuthToken {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        let (data, response) = try synchronousRequest(request)
        try checkHTTPStatus(response, data: data)
        let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        return StoredOAuthToken(response: decoded, previousRefreshToken: refreshToken)
    }

    static func formBody(_ fields: [String: String]) -> Data {
        fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
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
