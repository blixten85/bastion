#if os(tvOS)
import Foundation
import SSHCore

/// Konfiguration för en OAuth 2.0 Device Authorization Grant-leverantör
/// (RFC 8628) — det enda OAuth-flödet som faktiskt fungerar på tvOS/watchOS
/// eftersom `ASWebAuthenticationSession` är `API_UNAVAILABLE(watchos, tvos)`
/// (verifierat mot Apples egen SDK-header, se
/// [[project-bastion-tvos-watchos-mandate]]). Google och Microsoft stödjer
/// detta flödet (verifierat mot developers.google.com/identity/protocols/
/// oauth2/limited-input-device och learn.microsoft.com/entra/identity-
/// platform/v2-oauth2-device-code, 2026-07-21) — Dropbox gör det INTE
/// (bekräftat "wontfix" på dropbox/dropbox-api-spec#9), se
/// `TVSyncSettingsView.swift` för hur det visas i UI:t istället för att
/// tystas bort.
struct DeviceFlowProviderConfig {
    let id: String
    let displayName: String
    let deviceCodeEndpoint: URL
    let tokenEndpoint: URL
    let scope: String
    let clientID: String

    var isConfigured: Bool { !clientID.isEmpty }
}

enum TVOAuthProviders {
    // Kräver en "TVs and Limited Input devices"-klient i Google Cloud
    // Console (INTE samma klienttyp som PKCE-flödet i App/OAuthProviders.swift
    // använder) — se README "Kontointegration" när den registreras.
    static let googleDrive = DeviceFlowProviderConfig(
        id: "googledrive",
        displayName: "Google Drive",
        deviceCodeEndpoint: URL(string: "https://oauth2.googleapis.com/device/code")!,
        tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
        scope: "https://www.googleapis.com/auth/drive.appdata",
        clientID: ""
    )

    // "common"-tenant (personliga + jobb/skol-konton) — samma val som
    // PKCE-flödet i App/OAuthProviders.swift redan gör.
    static let oneDrive = DeviceFlowProviderConfig(
        id: "onedrive",
        displayName: "OneDrive",
        deviceCodeEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode")!,
        tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
        scope: "Files.ReadWrite.AppFolder offline_access",
        clientID: ""
    )

    static let all: [DeviceFlowProviderConfig] = [googleDrive, oneDrive]
}

/// Rått svar från `deviceCodeEndpoint` — Google kallar fältet
/// `verification_url`, Microsoft `verification_uri` (samma betydelse, olika
/// namn, bekräftat i respektive dokumentation) — `verificationURL` slår
/// ihop dem så anroparen slipper bry sig om vilken leverantör det är.
private struct DeviceCodeResponse: Decodable {
    let device_code: String
    let user_code: String
    let verification_uri: String?
    let verification_url: String?
    let expires_in: Int
    let interval: Int?

    var verificationURL: String { verification_uri ?? verification_url ?? "" }
}

private struct DeviceFlowErrorResponse: Decodable {
    let error: String
    let error_description: String?
}

/// Vad UI:t visar användaren medan hen loggar in på en annan enhet.
struct DeviceFlowSession {
    let userCode: String
    let verificationURL: String
    let expiresAt: Date
}

@MainActor
enum TVDeviceFlowOAuthManager {
    static func isLoggedIn(_ provider: DeviceFlowProviderConfig) -> Bool {
        TVOAuthTokenStore.isLoggedIn(provider.id)
    }

    static func logout(_ provider: DeviceFlowProviderConfig) {
        TVOAuthTokenStore.logout(provider.id)
    }

    /// Steg 1: begär enhets-/användarkod. Anroparen visar koden/URL:en
    /// direkt, sedan `waitForLogin` för att polla klart.
    static func begin(_ provider: DeviceFlowProviderConfig) async throws -> (DeviceFlowSession, PendingDeviceCode) {
        guard provider.isConfigured else { throw OAuthError.notConfigured }
        var request = URLRequest(url: provider.deviceCodeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = TVOAuthTokenStore.formBody(["client_id": provider.clientID, "scope": provider.scope])
        let (data, response) = try await URLSession.shared.data(for: request)
        try TVOAuthTokenStore.checkHTTPStatus(response, data: data)
        let decoded = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        let session = DeviceFlowSession(
            userCode: decoded.user_code,
            verificationURL: decoded.verificationURL,
            expiresAt: Date().addingTimeInterval(Double(decoded.expires_in))
        )
        let pending = PendingDeviceCode(
            provider: provider, deviceCode: decoded.device_code,
            interval: decoded.interval ?? 5, expiresAt: session.expiresAt
        )
        return (session, pending)
    }

    /// Steg 2: pollar `tokenEndpoint` tills användaren loggat in (eller
    /// nekat/tiden gått ut). Körs i en separat `Task` av anroparen medan
    /// koden från `begin` visas på skärmen.
    static func waitForLogin(_ pending: PendingDeviceCode) async throws {
        var interval = pending.interval
        while Date() < pending.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            var request = URLRequest(url: pending.provider.tokenEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = TVOAuthTokenStore.formBody([
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": pending.provider.clientID,
                "device_code": pending.deviceCode,
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OAuthError.requestFailed("inget svar") }
            if (200..<300).contains(http.statusCode) {
                let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
                try TVOAuthTokenStore.save(StoredOAuthToken(response: decoded), for: pending.provider.id)
                return
            }
            let errorBody = try? JSONDecoder().decode(DeviceFlowErrorResponse.self, from: data)
            switch errorBody?.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
                continue
            case "access_denied", "authorization_declined":
                throw OAuthError.accessDenied
            case "expired_token":
                throw OAuthError.expired
            default:
                throw OAuthError.requestFailed(errorBody?.error_description ?? String(decoding: data, as: UTF8.self))
            }
        }
        throw OAuthError.expired
    }
}

/// Håller det `waitForLogin` behöver mellan `begin`/`waitForLogin`-anropen
/// — inte del av `DeviceFlowSession` eftersom UI:t bara ska visa/binda mot
/// den, aldrig läsa `deviceCode` (den är hemlig, inte tänkt att visas).
struct PendingDeviceCode {
    let provider: DeviceFlowProviderConfig
    let deviceCode: String
    let interval: Int
    let expiresAt: Date
}
#endif
