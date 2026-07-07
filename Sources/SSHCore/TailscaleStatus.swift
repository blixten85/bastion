import Foundation

/// Parsning av `tailscale status --json` — för att föreslå värdar ur
/// användarens tailnet (samma idé som ssh-config-import, men källan är
/// Tailscales egen lokala daemon istället för en textfil).
///
/// **Viktig begränsning, medvetet**: Tailscale dokumenterar INTE det här
/// JSON-formatet som en stabil, garanterad kontraktsyta — bara att det är
/// tänkt för automatisering. Fälten här är verifierade mot en RIKTIG,
/// lokalt installerad `tailscaled` (v1.98.8, `tailscale status --json`
/// kört på riktigt, inte gissat), inte mot en formell spec. Kan behöva
/// uppdateras om en framtida Tailscale-version ändrar formatet. `Self`
/// och varje `Peer`-post delar samma `PeerStatus`-typ i Tailscales egen
/// Go-källkod, så fältnamnen som verifierats via `Self` (den enda posten
/// som gick att observera utan en riktig inloggad tailnet-anslutning)
/// gäller rimligen även för `Peer`-posterna.
public struct TailscaleStatus: Codable, Sendable, Equatable {
    public struct PeerInfo: Codable, Sendable, Equatable {
        public let hostName: String
        public let dnsName: String
        public let os: String
        public let tailscaleIPs: [String]?
        public let online: Bool

        enum CodingKeys: String, CodingKey {
            case hostName = "HostName"
            case dnsName = "DNSName"
            case os = "OS"
            case tailscaleIPs = "TailscaleIPs"
            case online = "Online"
        }
    }

    public let version: String
    public let backendState: String
    public let selfNode: PeerInfo?
    public let peer: [String: PeerInfo]?

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case backendState = "BackendState"
        case selfNode = "Self"
        case peer = "Peer"
    }

    public static func parse(jsonData: Data) throws -> TailscaleStatus {
        try JSONDecoder().decode(TailscaleStatus.self, from: jsonData)
    }

    /// Föreslagna värdar ur tailnet — bara peers som faktiskt är online
    /// och har minst en Tailscale-IP, sorterade på värdnamn. Filtrerar bort
    /// `hostName`/`dnsName` eftersom `DNSName` (MagicDNS, t.ex.
    /// `min-server.tailXXXX.ts.net`) är stabilare/mer användbart som
    /// anslutningsmål än det korta `HostName` när MagicDNS är aktiverat —
    /// men faller tillbaka till `hostName` om `dnsName` saknas (peer utan
    /// MagicDNS, eller en äldre Tailscale-version).
    public var suggestedHosts: [(hostName: String, address: String)] {
        (peer ?? [:]).values
            .filter { $0.online }
            .compactMap { info -> (String, String)? in
                guard let ip = info.tailscaleIPs?.first else { return nil }
                let name = info.dnsName.isEmpty ? info.hostName : info.dnsName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return (name, ip)
            }
            .sorted { $0.0.lowercased() < $1.0.lowercased() }
    }
}
