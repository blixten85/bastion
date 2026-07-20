import Foundation

/// Varför `ConnectionPlanning.plan` inte kunde ge en anslutningsplan.
/// Ren, testbar `Result`-motpart till det `nil` som `App/AuthResolver.
/// resolveConnectionPlan` idag kollapsar alla dessa fall till (cubic-fynd
/// på PR #172: en generisk "autentiseringsfel" döljer vilket av dessa fyra
/// fall det faktiskt var). Att plumba orsaken hela vägen till UI kräver att
/// ändra `resolveConnectionPlan`s signatur i ~16 anropsplatser (App/ +
/// LinuxApp/) — ett scopat uppföljningsarbete, inte gjort här. Den här typen
/// finns redan så policyn kan testas oberoende av det.
public enum ConnectionPlanFailure: Error, Sendable, Equatable {
    /// Målets egen auth kunde inte lösas upp.
    case targetAuthFailed
    /// `jumpHostID` är satt men hittades inte i `store` (borttagen/okänd).
    case jumpHostMissing
    /// Jump-hosten SJÄLV har en `jumpHostID` satt — `SSHConnectionChain`
    /// stöder bara ETT hopp, så en kedja A→B→C skulle annars tyst bli A→B.
    case jumpHostNested
    /// Jump-hostens egen auth kunde inte lösas upp.
    case jumpAuthFailed
}

/// Ren regel för target+jump-uppslagning, oberoende av HUR auth faktiskt
/// löses upp (Keychain/Bitwarden/nyckelfil hör hemma i
/// `App/AuthResolver.resolveAuth`, som inte finns i SSHCore) — det gör
/// själva policyn testbar i `SSHCoreTests` utan Xcode. Samma kontrakt som
/// `SessionView.plan` redan hade: en konfigurerad jump-host FAILAR
/// anslutningen om den inte går att lösa upp, hoppas ALDRIG över tyst.
public enum ConnectionPlanning {
    public static func plan(
        targetAuth: SSHAuth?,
        jumpHostID: UUID?,
        jumpHost: Host?,
        jumpAuth: SSHAuth?
    ) -> Result<(auth: SSHAuth, jump: (target: SSHTarget, auth: SSHAuth)?), ConnectionPlanFailure> {
        guard let targetAuth else { return .failure(.targetAuthFailed) }
        guard let jumpHostID else { return .success((targetAuth, nil)) }
        guard let jumpHost, jumpHost.id == jumpHostID else { return .failure(.jumpHostMissing) }
        guard jumpHost.jumpHostID == nil else { return .failure(.jumpHostNested) }
        guard let jumpAuth else { return .failure(.jumpAuthFailed) }
        return .success((targetAuth, (jumpHost.target, jumpAuth)))
    }
}
