#if canImport(SwiftUI)
import Foundation

/// Beskriver en OAuth2-leverantör för PKCE-inloggning mot en app-scopad mapp
/// (Dropbox "App folder"-behörighet, Google Drives `drive.appdata`-scope,
/// OneDrives `Files.ReadWrite.AppFolder`) — appen ber aldrig om åtkomst till
/// hela kontot.
///
/// `clientID` är tom tills DU registrerar en app hos leverantören och fyller i
/// den + registrerar `redirectURI` där. Se README "Kontointegration" för
/// exakta steg per leverantör. Inget av det här kan kodas i förväg — varje
/// leverantör kräver ett konto och en app-registrering hos just dig.
struct OAuthProviderConfig {
    let id: String // Keychain-nyckelprefix
    let displayName: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let scope: String
    let redirectURI: URL
    let clientID: String

    var isConfigured: Bool { !clientID.isEmpty }
}

enum OAuthProviders {
    static let dropbox = OAuthProviderConfig(
        id: "dropbox",
        displayName: "Dropbox",
        authorizationEndpoint: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
        tokenEndpoint: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
        scope: "files.content.write files.content.read",
        redirectURI: URL(string: "se.denied.bastion://oauth/dropbox")!,
        clientID: "ira5qtb04w4qikk"
    )

    static let googleDrive = OAuthProviderConfig(
        id: "googledrive",
        displayName: "Google Drive",
        authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
        scope: "https://www.googleapis.com/auth/drive.appdata",
        redirectURI: URL(string: "se.denied.bastion://oauth/googledrive")!,
        clientID: ""
    )

    static let oneDrive = OAuthProviderConfig(
        id: "onedrive",
        displayName: "OneDrive",
        authorizationEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
        tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
        scope: "Files.ReadWrite.AppFolder offline_access",
        redirectURI: URL(string: "se.denied.bastion://oauth/onedrive")!,
        clientID: ""
    )

    static let all: [OAuthProviderConfig] = [dropbox, googleDrive, oneDrive]
}
#endif
