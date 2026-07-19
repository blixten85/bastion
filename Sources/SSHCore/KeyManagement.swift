import Crypto
import Foundation
import NIOSSH

/// Ett nygenererat Ed25519-nyckelpar: fröet (för `SSHAuth.ed25519Seed`/Keychain-
/// lagring) och den publika raden i OpenSSH-format (för `authorized_keys`/export).
public struct GeneratedKeyPair: Sendable {
    public let seed: Data
    public let publicKeyLine: String
}

public enum KeyGenerator {
    /// Genererar ett helt nytt, slumpmässigt Ed25519-nyckelpar. `comment`
    /// bifogas den publika raden (samma konvention som `ssh-keygen -C`) —
    /// rent kosmetiskt, ingen del av själva nyckelmaterialet.
    public static func generateEd25519(comment: String = "") -> GeneratedKeyPair {
        let privateKey = Curve25519.Signing.PrivateKey()
        // rawRepresentation kommer alltid vara giltig här (precis genererad
        // av Curve25519 självt) — try! är säkert bara på den HÄR interna
        // anropsvägen, till skillnad från den publika fromExisting(seed:)
        // nedan som MÅSTE kunna kasta ett tydligt fel för godtyckliga,
        // användarinmatade frön.
        return try! fromExisting(seed: privateKey.rawRepresentation, comment: comment)
    }

    /// Bygger ett `GeneratedKeyPair` (för `deployPublicKey`/`verifyKeyAuthWorks`)
    /// ur ett REDAN BEFINTLIGT Ed25519-frö istället för att slumpa fram ett
    /// nytt — samma härledningslogik som `generateEd25519`, bara med fröet
    /// som indata. Används av "klistra in en befintlig nyckel och deploya
    /// den"-flödet (`KeyDeployModel.importExisting`): en användare som redan
    /// har en nyckel de vill INSTALLERA på en ny server, inte generera en
    /// helt ny för. Kastar (istället för att krascha) om `seed` inte är ett
    /// giltigt 32-byte Ed25519-frö — skiljer sig från `generateEd25519` där
    /// fröet alltid kommer från Curve25519 självt och därför alltid är giltigt.
    public static func fromExisting(seed: Data, comment: String = "") throws -> GeneratedKeyPair {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let nioKey = NIOSSHPrivateKey(ed25519Key: privateKey)
        var line = String(openSSHPublicKey: nioKey.publicKey)
        if !comment.isEmpty { line += " " + comment }
        return GeneratedKeyPair(seed: privateKey.rawRepresentation, publicKeyLine: line)
    }
}

/// Escapar en sträng säkert för inbäddning i ETT enkelcitat POSIX shell-
/// argument: avsluta citatet, lägg till en escapad enkelcitation, öppna
/// citatet igen (`'` -> `'\''`). Nödvändigt eftersom en nyckelkommentar är
/// fri text från användaren, inte ett validerbart smalt format (till skillnad
/// från `DockerService.validate`s namn-allowlist).
func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Vilken sorts fjärrsystem `deployPublicKey` ska bygga ett kommando för.
/// Windows OpenSSH har en avsiktlig säkerhetsregel som gör att admin- och
/// standardkonton måste hanteras helt olika (se `RemotePlatform.windowsAdmin`),
/// och Bastion har ingen tillförlitlig, riskfri fjärrdetektion av det här —
/// därför ett explicit fält på host-profilen (`Host.platform`) istället för
/// att gissa via en sond.
public enum RemotePlatform: String, Codable, Sendable, CaseIterable, CustomStringConvertible {
    /// Linux/macOS — standard `~/.ssh/authorized_keys`.
    case posix
    /// Windows, konto i Administrators-gruppen. Win32-OpenSSH IGNORERAR
    /// `~/.ssh/authorized_keys` helt för såna konton — kräver den delade
    /// `C:\ProgramData\ssh\administrators_authorized_keys` med strikta ACL:er
    /// (bara SYSTEM+Administrators, ärvda behörigheter avstängda), annars
    /// vägrar sshd använda filen. Verifierat mot en riktig Windows Server
    /// 2025-VPS (2026-07-06).
    case windowsAdmin
    /// Windows, vanligt (icke-admin) konto — `%USERPROFILE%\.ssh\authorized_keys`,
    /// inga särskilda ACL-krav.
    case windowsStandard

    public var description: String {
        switch self {
        case .posix: return "Linux/macOS"
        case .windowsAdmin: return "Windows (adminkonto)"
        case .windowsStandard: return "Windows (standardkonto)"
        }
    }
}

/// Bygger kommandot som lägger till `publicKeyLine` i `~/.ssh/authorized_keys`
/// — idempotent (kör om säkert, aldrig dubblettrader), skapar `~/.ssh` med
/// rätt rättigheter (700/600) om den saknas. Egen funktion (inte inline i
/// `deployPublicKey`) just för att kunna testa den exakta kommandosträngen
/// utan en riktig SSH-anslutning.
func deployPublicKeyCommandPOSIX(_ publicKeyLine: String) -> String {
    let quoted = shellQuoted(publicKeyLine)
    return """
    mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && \
    chmod 600 ~/.ssh/authorized_keys && \
    (grep -qxF \(quoted) ~/.ssh/authorized_keys || echo \(quoted) >> ~/.ssh/authorized_keys)
    """
}

/// Bygger ett Windows-kommando som anropar `powershell -EncodedCommand` med
/// hela skriptet Base64/UTF-16LE-kodat — undviker helt att behöva escapa en
/// fri kommentarsträng genom TVÅ nästlade skallager (SSH-exec-argumentet OCH
/// cmd.exe/PowerShells egen citering). Base64 innehåller bara
/// `[A-Za-z0-9+/=]`, alla säkra oquotade i cmd.exe.
///
/// `setACL`: bara `.windowsAdmin` behöver `icacls`-låsningen — Win32-OpenSSH
/// vägrar annars filen helt. Standardkontots egen `.ssh`-mapp har inga såna krav.
func deployPublicKeyCommandWindows(_ publicKeyLine: String, path: String, setACL: Bool) -> String {
    // Enkelcitat i PowerShell: `'` blir `''` (fördubblad), inte `\'` som i POSIX-skal.
    let psQuoted = "'" + publicKeyLine.replacingOccurrences(of: "'", with: "''") + "'"
    let psPath = "'" + path.replacingOccurrences(of: "'", with: "''") + "'"
    // INTE NSString.deletingLastPathComponent — den antar POSIX-snedstreck
    // som separator och skulle inte dela upp en backslash-separerad Windows-
    // sökväg (eller en med `$env:...`-prefix) korrekt alls.
    let dir = path.split(separator: "\\", omittingEmptySubsequences: false).dropLast().joined(separator: "\\")
    let psDir = "'" + dir.replacingOccurrences(of: "'", with: "''") + "'"

    var script = """
    $ErrorActionPreference = 'Stop'
    $key = \(psQuoted)
    $path = \(psPath)
    $dir = \(psDir)
    if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (!(Test-Path $path) -or -not (Select-String -Path $path -Pattern ([regex]::Escape($key)) -SimpleMatch -Quiet)) {
        Add-Content -Path $path -Value $key
    }
    """
    if setACL {
        script += """

        icacls $path /inheritance:r | Out-Null
        icacls $path /grant SYSTEM:F /grant Administrators:F | Out-Null
        """
    }

    let utf16 = Data(script.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    let encoded = utf16.base64EncodedString()
    return "powershell -NoProfile -NonInteractive -EncodedCommand \(encoded)"
}

extension SSHSession {
    /// Lägger till en publik nyckel i fjärrsidans `authorized_keys` — POSIX
    /// eller Windows (admin/standard), beroende på `platform`. Kräver en
    /// redan autentiserad session (vilken auth-metod som helst — det är
    /// separat från den nya nyckeln som deployas).
    public func deployPublicKey(_ publicKeyLine: String, platform: RemotePlatform = .posix) async throws {
        let command: String
        switch platform {
        case .posix:
            command = deployPublicKeyCommandPOSIX(publicKeyLine)
        case .windowsAdmin:
            command = deployPublicKeyCommandWindows(
                publicKeyLine, path: #"C:\ProgramData\ssh\administrators_authorized_keys"#, setACL: true)
        case .windowsStandard:
            command = deployPublicKeyCommandWindows(
                publicKeyLine, path: #"$env:USERPROFILE\.ssh\authorized_keys"#, setACL: false)
        }
        for try await _ in execute(command) {}
    }

    /// Öppnar en TYST, separat anslutning mot samma mål med den angivna
    /// nyckeln och kontrollerar att autentiseringen faktiskt lyckas. Används
    /// för att bevisa att en nyss deployad nyckel verkligen fungerar INNAN
    /// ett lösenord tas bort ur Bastions egen lagring för host-profilen.
    /// `jump` speglar `SSHConnectionChain.connect(target:targetAuth:jump:)` —
    /// target bakom en jump-host är annars overifierbar (probe:en skulle
    /// försöka nå target direkt och alltid misslyckas).
    ///
    /// Kör ETT no-op-kommando innan den rapporterar lyckat resultat —
    /// `SSHConnectionChain.connect` ENSAMT räcker INTE som bevis: en
    /// target-auth-misslyckning genom en jump-host kan vara asynkron och
    /// synas först vid första faktiska kanalanvändningen (dokumenterat av
    /// `ProxyJumpTests.testConnectionChainClosesJumpWhenTargetAuthFails` —
    /// samma repo, samma beteende). Utan detta hade en trasig nyckel kunnat
    /// rapporteras som "verifierad" och låsa ute användaren när lösenordet
    /// sedan tas bort (codex-fynd, PR #172).
    public static func verifyKeyAuthWorks(
        target: SSHTarget, seed: Data, knownHosts: KnownHosts,
        jump: (target: SSHTarget, auth: SSHAuth)? = nil
    ) async -> Bool {
        do {
            let chain = try await SSHConnectionChain.connect(
                target: target, targetAuth: .ed25519Seed(seed), jump: jump, knownHosts: knownHosts)
            do {
                _ = try await chain.target.run("exit 0")
                await chain.close()
                guard !Task.isCancelled else { return false }
                return true
            } catch {
                await chain.close()
                return false
            }
        } catch {
            return false
        }
    }
}
