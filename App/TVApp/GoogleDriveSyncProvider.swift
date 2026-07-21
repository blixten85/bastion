#if os(tvOS)
import Foundation
import SSHCore

/// tvOS-motsvarighet till `App/GoogleDriveSyncProvider.swift` — identisk
/// Drive-logik, bara `token()` omdirigerad till `TVOAuthTokenStore`/
/// `TVOAuthProviders` (device-flow-inloggning, se
/// `TVDeviceFlowOAuthManager.swift`) istället för den PKCE-baserade
/// `OAuthTokenStore`/`OAuthProviders` i App/.
struct GoogleDriveSyncProvider: SyncProvider {
    private let filename: String
    private let passphrase: String

    init(filename: String = "bastion-sync.enc", passphrase: String) {
        self.filename = filename
        self.passphrase = passphrase
    }

    func pull() throws -> SyncState? {
        guard let fileID = try findFileID() else { return nil }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media")!)
        request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try TVOAuthTokenStore.synchronousRequest(request)
        try TVOAuthTokenStore.checkHTTPStatus(response, data: data)
        return try SyncCrypto.open(data, passphrase: passphrase)
    }

    func push(_ state: SyncState) throws {
        let payload = try SyncCrypto.seal(state, passphrase: passphrase)
        if let fileID = try findFileID() {
            try update(fileID: fileID, payload: payload)
        } else {
            try create(payload: payload)
        }
    }

    private struct FileList: Decodable {
        struct Entry: Decodable { let id: String }
        let files: [Entry]
    }

    private func findFileID() throws -> String? {
        guard var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files") else {
            throw OAuthError.invalidCallback
        }
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "q", value: "name = '\(filename)'"),
            URLQueryItem(name: "fields", value: "files(id)"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try TVOAuthTokenStore.synchronousRequest(request)
        try TVOAuthTokenStore.checkHTTPStatus(response, data: data)
        return try JSONDecoder().decode(FileList.self, from: data).files.first?.id
    }

    private func create(payload: Data) throws {
        let boundary = "bastion-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(boundary: boundary, payload: payload)
        let (data, response) = try TVOAuthTokenStore.synchronousRequest(request)
        try TVOAuthTokenStore.checkHTTPStatus(response, data: data)
    }

    private func update(fileID: String, payload: Data) throws {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(fileID)?uploadType=media")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        let (data, response) = try TVOAuthTokenStore.synchronousRequest(request)
        try TVOAuthTokenStore.checkHTTPStatus(response, data: data)
    }

    private func multipartBody(boundary: String, payload: Data) throws -> Data {
        let metadata = try JSONSerialization.data(withJSONObject: ["name": filename, "parents": ["appDataFolder"]])
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadata)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(payload)
        body.append("\r\n--\(boundary)--".data(using: .utf8)!)
        return body
    }

    private func token() throws -> String {
        try TVOAuthTokenStore.validAccessToken(
            for: TVOAuthProviders.googleDrive.id,
            tokenEndpoint: TVOAuthProviders.googleDrive.tokenEndpoint,
            clientID: TVOAuthProviders.googleDrive.clientID)
    }
}
#endif
