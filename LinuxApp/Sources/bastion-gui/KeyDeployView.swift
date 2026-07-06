import Foundation
import SSHCore
import SwiftCrossUI

/// Generera en ny SSH-nyckel, deploya den till fjärrsidans `authorized_keys`,
/// verifiera tyst att den faktiskt fungerar — och ENDAST om det lyckas,
/// erbjud (opt-in, aldrig automatiskt) att byta host-profilen till
/// nyckel-auth. Motsvarande "ta bort lösenordet" betyder här bara att sluta
/// FRÅGA efter lösenord för den här profilen (`.askPassword` -> `.keyFile`) —
/// LinuxApp har ingen Keychain och sparar aldrig själva lösenordet på disk
/// till att börja med, så det finns inget hemligt värde att radera separat.
/// Rör ALDRIG fjärrserverns egen autentiseringskonfiguration.
@MainActor
final class KeyDeployModel: ObservableObject {
    @Published var generatedKey: GeneratedKeyPair?
    @Published var deployed = false
    @Published var verified = false
    @Published var statusMessage: String?
    @Published var busy = false
    private let host: Host
    private let password: String?
    private let comment: String

    init(host: Host, password: String?) {
        self.host = host
        self.password = password
        self.comment = "bastion-\(host.alias.isEmpty ? host.hostName : host.alias)"
    }

    func generate() {
        generatedKey = KeyGenerator.generateEd25519(comment: comment)
        deployed = false
        verified = false
        statusMessage = nil
    }

    func deployAndVerify() async {
        guard let key = generatedKey else { return }
        busy = true
        defer { busy = false }
        guard let auth = resolveAuth(for: host, password: password) else {
            statusMessage = "Kan inte autentisera värden."
            return
        }
        let session = SSHSession(target: host.target, auth: auth)
        do {
            try await session.connect()
            try await session.deployPublicKey(key.publicKeyLine, platform: host.platform)
            await session.close()
            deployed = true
        } catch {
            statusMessage = "Deploy misslyckades: \(error)"
            return
        }

        let ok = await SSHSession.verifyKeyAuthWorks(
            target: host.target, seed: key.seed, knownHosts: KnownHosts())
        verified = ok
        statusMessage = ok
            ? "Nyckeln verifierad — fungerar."
            : "Verifiering misslyckades. Lösenordet är kvar, ingenting ändrat."
    }

    /// Skriver nyckeln till disk (`~/.bastion/keys/<host-id>_ed25519`, 0600)
    /// och returnerar en uppdaterad `Host` med `auth = .keyFile(path)`.
    /// Anropas bara efter att `verified` är sant — vyns checkbox styr NÄR,
    /// inte modellen (opt-in, matchar användarens uttryckliga krav).
    func saveKeyAndSwitchAuth() throws -> Host {
        guard let key = generatedKey, verified else {
            throw SSHError.channelFailed("nyckeln är inte verifierad än")
        }
        let dir = ("~/.bastion/keys" as NSString).expandingTildeInPath
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/\(host.id.uuidString)_ed25519"
        let pem = try OpenSSHPrivateKey.export(seed: key.seed, comment: comment)
        try pem.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        var updated = host
        updated.auth = .keyFile(path)
        return updated
    }
}

struct KeyDeployView: View {
    @State private var model: KeyDeployModel
    @State private var switchAuthAfterVerify = false
    @State private var saveError: String?
    let onHostUpdated: (Host) -> Void

    init(host: Host, password: String?, onHostUpdated: @escaping (Host) -> Void) {
        self._model = State(wrappedValue: KeyDeployModel(host: host, password: password))
        self.onHostUpdated = onHostUpdated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SSH-nyckel").font(.headline)
            Text("Genererar en ny Ed25519-nyckel, installerar den på fjärrservern och verifierar att den fungerar innan något ändras lokalt.")
                .foregroundColor(.gray)

            if let key = model.generatedKey {
                Text("Publik nyckel:").font(.subheadline)
                Text(key.publicKeyLine)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let s = model.statusMessage {
                Text(s).foregroundColor(model.verified ? .green : .red)
            }
            if let e = saveError {
                Text(e).foregroundColor(.red)
            }

            HStack {
                Button(model.generatedKey == nil ? "Generera nyckel" : "Generera ny nyckel") {
                    model.generate()
                }
                if model.generatedKey != nil {
                    Button(model.busy ? "Arbetar…" : "Deploya + verifiera") {
                        Task { await model.deployAndVerify() }
                    }
                    .disabled(model.busy)
                }
            }

            if model.verified {
                Toggle("Byt den här värden till nyckel-auth (fråga inte längre efter lösenord)", isOn: $switchAuthAfterVerify)
                Button("Bekräfta") { confirm() }
                    .disabled(!switchAuthAfterVerify)
            }
        }
        .padding()
    }

    private func confirm() {
        do {
            let updated = try model.saveKeyAndSwitchAuth()
            onHostUpdated(updated)
        } catch {
            saveError = "\(error)"
        }
    }
}
