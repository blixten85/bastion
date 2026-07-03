#if canImport(SwiftUI)
import AuthenticationServices
import Foundation
import SSHCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Interaktiv PKCE-inloggning via systemets webbvy (`ASWebAuthenticationSession`).
/// Token-lagring/förnyelse ligger i `OAuthTokenStore` (inte MainActor-bunden),
/// så `SyncProvider`s synkrona `pull()/push()` kan anropa den från en
/// bakgrundstråd utan att vänta på huvudtråden.
///
/// OBS: den här filen (och `ASWebAuthenticationSession`-flödet den bygger på)
/// är inte byggd/testad här — appen är Xcode-only och kan inte kompileras på
/// Linux. Verifiera i Xcode innan den litas på. `OAuthPKCE`-kärnlogiken den
/// bygger på är däremot testad (se `Tests/SSHCoreTests/OAuthPKCETests.swift`,
/// verifierad mot RFC 7636).
@MainActor
final class OAuthAccountManager: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthAccountManager()
    private var activeSession: ASWebAuthenticationSession?

    func isLoggedIn(_ provider: OAuthProviderConfig) -> Bool { OAuthTokenStore.isLoggedIn(provider) }
    func logout(_ provider: OAuthProviderConfig) { OAuthTokenStore.logout(provider) }

    func login(_ provider: OAuthProviderConfig) async throws {
        guard provider.isConfigured else { throw OAuthError.notConfigured }

        let verifier = OAuthPKCE.makeVerifier()
        let challenge = OAuthPKCE.challenge(forVerifier: verifier)
        let state = OAuthPKCE.makeVerifier()

        guard var components = URLComponents(url: provider.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidCallback
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: provider.clientID),
            URLQueryItem(name: "redirect_uri", value: provider.redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: provider.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = components.url else { throw OAuthError.invalidCallback }

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: provider.redirectURI.scheme
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? OAuthError.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            activeSession = session
            session.start()
        }

        guard
            let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value,
            callbackComponents.queryItems?.first(where: { $0.name == "state" })?.value == state
        else {
            throw OAuthError.invalidCallback
        }

        let token = try await exchangeCodeForToken(code: code, verifier: verifier, provider: provider)
        try OAuthTokenStore.save(token, for: provider)
    }

    private func exchangeCodeForToken(code: String, verifier: String, provider: OAuthProviderConfig) async throws -> StoredOAuthToken {
        var request = URLRequest(url: provider.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthTokenStore.formBody([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": provider.redirectURI.absoluteString,
            "client_id": provider.clientID,
            "code_verifier": verifier,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try OAuthTokenStore.checkHTTPStatus(response, data: data)
        let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        return StoredOAuthToken(response: decoded)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }
}
#endif
