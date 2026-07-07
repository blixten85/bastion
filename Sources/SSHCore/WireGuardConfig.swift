import Foundation

/// En WireGuard-profil (`.conf`-filen `wg-quick`/`wg setconf` läser). v1:
/// parsning/lagring/redigering — INTE att faktiskt upprätta tunneln (kräver
/// `wg`-binären + root, och ett helt eget kryptoprotokoll om det skulle göras
/// utan den binären — separat, mycket större arbete, se ROADMAP).
///
/// Formatet verifierat mot `wg(8)` och `wg-quick(8)` (man7.org), inte
/// gissat ur minnet: `[Interface]`-sektionen bär `PrivateKey`/`ListenPort`/
/// `FwMark` (wg(8)) samt `Address`/`DNS`/`MTU`/`Table`/`PreUp`/`PostUp`/
/// `PreDown`/`PostDown`/`SaveConfig` (wg-quick-tillägg); `[Peer]`-sektionen
/// bär `PublicKey`/`PresharedKey`/`AllowedIPs`/`Endpoint`/`PersistentKeepalive`.
public struct WireGuardConfig: Sendable, Equatable {
    public struct Interface: Sendable, Equatable {
        public var privateKey: String?
        public var address: [String] = []
        public var dns: [String] = []
        public var listenPort: Int?
        public var mtu: Int?
        public var table: String?
        public var preUp: [String] = []
        public var postUp: [String] = []
        public var preDown: [String] = []
        public var postDown: [String] = []
        public var saveConfig: Bool?
        public var fwMark: String?

        public init(
            privateKey: String? = nil, address: [String] = [], dns: [String] = [],
            listenPort: Int? = nil, mtu: Int? = nil, table: String? = nil,
            preUp: [String] = [], postUp: [String] = [], preDown: [String] = [], postDown: [String] = [],
            saveConfig: Bool? = nil, fwMark: String? = nil
        ) {
            self.privateKey = privateKey
            self.address = address
            self.dns = dns
            self.listenPort = listenPort
            self.mtu = mtu
            self.table = table
            self.preUp = preUp
            self.postUp = postUp
            self.preDown = preDown
            self.postDown = postDown
            self.saveConfig = saveConfig
            self.fwMark = fwMark
        }
    }

    public struct Peer: Sendable, Equatable {
        public var publicKey: String?
        public var presharedKey: String?
        public var allowedIPs: [String] = []
        public var endpoint: String?
        public var persistentKeepalive: Int?

        public init(
            publicKey: String? = nil, presharedKey: String? = nil, allowedIPs: [String] = [],
            endpoint: String? = nil, persistentKeepalive: Int? = nil
        ) {
            self.publicKey = publicKey
            self.presharedKey = presharedKey
            self.allowedIPs = allowedIPs
            self.endpoint = endpoint
            self.persistentKeepalive = persistentKeepalive
        }
    }

    public var interface = Interface()
    public var peers: [Peer] = []

    public init(interface: Interface = Interface(), peers: [Peer] = []) {
        self.interface = interface
        self.peers = peers
    }

    // MARK: - Parsning

    private enum Section { case none, interface, peer }

    /// `#` inleder en kommentar (till radslutet), `[Section]`-rubriker,
    /// `Key = Value`-par — nycklar skiftlägesokänsliga (verkliga `.conf`-
    /// filer varierar), värden trimmas. Kommaseparerade listor
    /// (`Address`/`DNS`/`AllowedIPs`) delas och trimmas per element.
    /// En nyckel som upprepas (t.ex. flera `Address`-rader, tillåtet enligt
    /// wg-quick) ackumuleras istället för att skriva över.
    public init(text: String) {
        var iface = Interface()
        var peerList: [Peer] = []
        var currentPeer: Peer?
        var section = Section.none

        func flushPeer() {
            if let p = currentPeer { peerList.append(p) }
            currentPeer = nil
        }

        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            // omittingEmptySubsequences: false är nödvändigt — annars tappas
            // den TOMMA prefixen på en rad som BÖRJAR med "#" (t.ex. en
            // helt utkommenterad "#Address = ..."), och split(...).first
            // skulle då plocka ut det som kommer EFTER "#" istället för att
            // korrekt ge en tom rad (CodeRabbit-fynd, PR #79, bevisat med
            // ett körbart Swift-exempel i granskningskommentaren).
            let withoutComment = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            let line = withoutComment.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                if name == "peer" {
                    flushPeer()
                    currentPeer = Peer()
                    section = .peer
                } else if name == "interface" {
                    flushPeer()
                    section = .interface
                } else {
                    flushPeer()
                    section = .none
                }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            func commaList(_ s: String) -> [String] {
                s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }

            switch section {
            case .interface:
                switch key {
                case "privatekey": iface.privateKey = value
                case "address": iface.address += commaList(value)
                case "dns": iface.dns += commaList(value)
                case "listenport": iface.listenPort = Int(value)
                case "mtu": iface.mtu = Int(value)
                case "table": iface.table = value
                case "preup": iface.preUp.append(value)
                case "postup": iface.postUp.append(value)
                case "predown": iface.preDown.append(value)
                case "postdown": iface.postDown.append(value)
                case "saveconfig": iface.saveConfig = (value.lowercased() == "true")
                case "fwmark": iface.fwMark = value
                default: break
                }
            case .peer:
                switch key {
                case "publickey": currentPeer?.publicKey = value
                case "presharedkey": currentPeer?.presharedKey = value
                case "allowedips": currentPeer?.allowedIPs += commaList(value)
                case "endpoint": currentPeer?.endpoint = value
                case "persistentkeepalive": currentPeer?.persistentKeepalive = Int(value)
                default: break
                }
            case .none:
                break
            }
        }
        flushPeer()
        self.interface = iface
        self.peers = peerList
    }

    // MARK: - Serialisering

    /// Skriver tillbaka till `.conf`-textformat — inversen av `init(text:)`.
    /// Fältordningen matchar `wg-quick`s egen konvention (Interface-nycklar
    /// i samma ordning som `wg-quick(8)` listar dem, sedan en `[Peer]`-
    /// sektion per peer).
    public func rendered() -> String {
        var lines: [String] = ["[Interface]"]
        if let v = interface.privateKey { lines.append("PrivateKey = \(v)") }
        if !interface.address.isEmpty { lines.append("Address = \(interface.address.joined(separator: ", "))") }
        if !interface.dns.isEmpty { lines.append("DNS = \(interface.dns.joined(separator: ", "))") }
        if let v = interface.listenPort { lines.append("ListenPort = \(v)") }
        if let v = interface.mtu { lines.append("MTU = \(v)") }
        if let v = interface.table { lines.append("Table = \(v)") }
        for v in interface.preUp { lines.append("PreUp = \(v)") }
        for v in interface.postUp { lines.append("PostUp = \(v)") }
        for v in interface.preDown { lines.append("PreDown = \(v)") }
        for v in interface.postDown { lines.append("PostDown = \(v)") }
        if let v = interface.saveConfig { lines.append("SaveConfig = \(v ? "true" : "false")") }
        if let v = interface.fwMark { lines.append("FwMark = \(v)") }

        for peer in peers {
            lines.append("")
            lines.append("[Peer]")
            if let v = peer.publicKey { lines.append("PublicKey = \(v)") }
            if let v = peer.presharedKey { lines.append("PresharedKey = \(v)") }
            if !peer.allowedIPs.isEmpty { lines.append("AllowedIPs = \(peer.allowedIPs.joined(separator: ", "))") }
            if let v = peer.endpoint { lines.append("Endpoint = \(v)") }
            if let v = peer.persistentKeepalive { lines.append("PersistentKeepalive = \(v)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
