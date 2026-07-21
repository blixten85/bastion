#if os(tvOS)
import Foundation
import SSHCore

/// tvOS-motsvarighet till `App/OneDriveSyncProvider.swift` — se
/// `GoogleDriveSyncProvider.swift` i samma mapp för samma resonemang
/// (bara `token()` omdirigerad till device-flow-lagringen).
struct OneDriveSyncProvider: SyncProvider {
    private let filename: String
    private let passphrase: String

    init(filename: String = "bastion-sync.enc", passphrase: String) {
        self.filename = filename
        self.passphrase = passphrase
    }

    private var contentURL: URL {
        // Procentkoda filnamnet innan det klistras in i sökvägen — annars
        // tolkar Graph-URL:en ett filnamn med "/" eller andra reserverade
        // tecken som en del av sökvägsstrukturen istället för ETT filnamn
        // (cubic P2). `urlPathAllowed` behåller vanliga tecken men kodar
        // bort "/"/":" m.fl.
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        return URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(encoded):/content")!
    }

    func pull() throws -> SyncState? {
        var request = URLRequest(url: contentURL)
        request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try TVOAuthTokenStore.synchronousRequest(request)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.requestFailed("inget svar") }
        if http.statusCode == 404 { return nil } // ingen fil sparad än
        try TVOAuthTokenStore.checkHTTPStatus(response, data: data)
        return try SyncCrypto.open(data, passphrase: passphrase)
    }

    func push(_ state: SyncState) throws {
        let payload = try SyncCrypto.seal(state, passphrase: passphrase)
        var request = URLRequest(url: contentURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        let (data, response) = try TVOAuthTokenStore.synchronousRequest(request)
        try TVOAuthTokenStore.checkHTTPStatus(response, data: data)
    }

    private func token() throws -> String {
        try TVOAuthTokenStore.validAccessToken(
            for: TVOAuthProviders.oneDrive.id,
            tokenEndpoint: TVOAuthProviders.oneDrive.tokenEndpoint,
            clientID: TVOAuthProviders.oneDrive.clientID)
    }
}
#endif
