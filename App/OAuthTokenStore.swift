#if canImport(SwiftUI)
import Foundation
import SSHCore

enum OAuthError: Error {
    case notConfigured
    case notLoggedIn
    case cancelled
    case invalidCallback
    case requestFailed(String)
    case keychainWriteFailed
}

/// Läser/skriver token i Keychain och förnyar tyst via `refresh_token`.
/// Medvetet INTE @MainActor — `SyncProvider.pull()/push()` (se
/// `DropboxSyncProvider.swift`) är synkrona och anropas från en bakgrundstråd,
/// inte huvudtråden, så den här måste kunna anropas därifrån.
enum OAuthTokenStore {
    private static func keychainKey(_ provider: OAuthProviderConfig, _ suffix: String) -> String {
        "oauth-\(provider.id)-\(suffix)"
    }

    static func isLoggedIn(_ provider: OAuthProviderConfig) -> Bool {
        Keychain.get(keychainKey(provider, "token")) != nil
    }

    static func logout(_ provider: OAuthProviderConfig) {
        Keychain.delete(keychainKey(provider, "token"))
    }

    static func save(_ token: StoredOAuthToken, for provider: OAuthProviderConfig) throws {
        let data = try JSONEncoder().encode(token)
        guard Keychain.set(String(decoding: data, as: UTF8.self), for: keychainKey(provider, "token")) else {
            throw OAuthError.keychainWriteFailed
        }
    }

    static func load(for provider: OAuthProviderConfig) -> StoredOAuthToken? {
        guard let json = Keychain.get(keychainKey(provider, "token")) else { return nil }
        return try? JSONDecoder().decode(StoredOAuthToken.self, from: Data(json.utf8))
    }

    /// Hämtar en giltig access token, förnyar tyst via `refresh_token` om den
    /// gått ut. Blockerande — matchar `SyncProvider`s synkrona gränssnitt
    /// (samma princip som `FolderSyncProvider`s blockerande filläsning).
    static func validAccessToken(for provider: OAuthProviderConfig) throws -> String {
        guard var token = load(for: provider) else { throw OAuthError.notLoggedIn }
        if token.isExpired, let refreshToken = token.refreshToken {
            token = try refresh(refreshToken, provider: provider)
            try save(token, for: provider)
        }
        return token.accessToken
    }

    private static func refresh(_ refreshToken: String, provider: OAuthProviderConfig) throws -> StoredOAuthToken {
        var request = URLRequest(url: provider.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": provider.clientID,
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

    /// Blockerande HTTP-anrop. Anropas bara från en bakgrundstråd (t.ex. via
    /// `HostListModel.syncNow()`), aldrig direkt från huvudtråden/UI:t.
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
