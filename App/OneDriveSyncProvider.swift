#if canImport(SwiftUI)
import Foundation
import SSHCore

/// OneDrive-backend för `SyncProvider`, mot appens särskilda "approot"-mapp
/// (Microsoft Graphs `special/approot`, kopplad till `Files.ReadWrite.AppFolder`-
/// scopet — aldrig hela OneDrive). Path-baserad som Dropbox, enklare än Google
/// Drive. Krypterar/dekrypterar med samma `SyncCrypto` som de andra providrarna.
///
/// OBS: inte byggd/testad här (Xcode-only, se `OAuthAccountManager.swift`).
struct OneDriveSyncProvider: SyncProvider {
    private let filename: String
    private let passphrase: String

    init(filename: String = "bastion-sync.enc", passphrase: String) {
        self.filename = filename
        self.passphrase = passphrase
    }

    private var contentURL: URL {
        URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(filename):/content")!
    }

    func pull() throws -> SyncState? {
        var request = URLRequest(url: contentURL)
        request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try OAuthTokenStore.synchronousRequest(request)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.requestFailed("inget svar") }
        if http.statusCode == 404 { return nil } // ingen fil sparad än
        try OAuthTokenStore.checkHTTPStatus(response, data: data)
        return try SyncCrypto.open(data, passphrase: passphrase)
    }

    func push(_ state: SyncState) throws {
        let payload = try SyncCrypto.seal(state, passphrase: passphrase)
        var request = URLRequest(url: contentURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        let (data, response) = try OAuthTokenStore.synchronousRequest(request)
        try OAuthTokenStore.checkHTTPStatus(response, data: data)
    }

    private func token() throws -> String {
        try OAuthTokenStore.validAccessToken(for: OAuthProviders.oneDrive)
    }
}
#endif
