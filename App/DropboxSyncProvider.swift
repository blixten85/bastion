#if canImport(SwiftUI)
import Foundation
import SSHCore

/// Dropbox-backend för `SyncProvider`, mot en fil i kontots App-mapp
/// (`files.content.write`/`files.content.read`-scope — aldrig hela kontot).
/// Krypterar/dekrypterar precis som `EncryptedFolderSyncProvider` (samma
/// `SyncCrypto`), bara transporten är Dropbox API i stället för en lokal
/// mapp — molntjänsten ser fortfarande bara chiffertext. Blockerande anrop,
/// som `FolderSyncProvider`. Google Drive/OneDrive följer samma mönster (byt
/// bara ut `pull()`/`push()`-anropen mot deras API:er — Google: `drive/v3/files`
/// med `appDataFolder`-scope, OneDrive/Graph: `me/drive/special/approot:/<fil>:/content`)
/// men är inte skrivna än.
///
/// OBS: inte byggd/testad här (Xcode-only, se `OAuthAccountManager.swift`).
struct DropboxSyncProvider: SyncProvider {
    private let path: String
    private let passphrase: String

    init(path: String = "/bastion-sync.enc", passphrase: String) {
        self.path = path
        self.passphrase = passphrase
    }

    func pull() throws -> SyncState? {
        var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        request.setValue(try argHeader(["path": path]), forHTTPHeaderField: "Dropbox-API-Arg")

        let (data, response) = try OAuthTokenStore.synchronousRequest(request)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.requestFailed("inget svar") }
        if http.statusCode == 409 { return nil } // path/not_found — inget synktillstånd sparat än
        try OAuthTokenStore.checkHTTPStatus(response, data: data)
        return try SyncCrypto.open(data, passphrase: passphrase)
    }

    func push(_ state: SyncState) throws {
        let payload = try SyncCrypto.seal(state, passphrase: passphrase)

        var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(try argHeader(["path": path, "mode": "overwrite"]), forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = payload

        let (data, response) = try OAuthTokenStore.synchronousRequest(request)
        try OAuthTokenStore.checkHTTPStatus(response, data: data)
    }

    private func token() throws -> String {
        try OAuthTokenStore.validAccessToken(for: OAuthProviders.dropbox)
    }

    private func argHeader(_ fields: [String: String]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    }
}
#endif
