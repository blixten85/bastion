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

public enum TailscaleStatusError: Error, Sendable, Equatable {
    /// Lokal `tailscale status --json`-körning gav en icke-noll exitkod.
    case localCommandFailed(exitCode: Int32, stderr: String)
}

extension TailscaleStatus {
    /// Kör `tailscale status --json` via SSH på en redan ansluten fjärrserver
    /// och tolkar svaret — samma mönster som `SystemProbe.snapshot(over:)`.
    /// Föreslår DEN SERVERNS tailnet-peers.
    public static func fetch(over session: SSHSession) async throws -> TailscaleStatus {
        let output = try await session.run("tailscale status --json 2>/dev/null")
        return try parse(jsonData: Data(output.utf8))
    }

    #if !os(iOS)
    /// Kör `tailscale status --json` LOKALT (Foundation `Process`) på
    /// maskinen appen själv exekverar på — samma idé som ssh-config-import
    /// läser en lokal fil, men källan här är Tailscales egen lokala daemon.
    /// Föreslår DENNA maskins tailnet-peers.
    ///
    /// Finns INTE på iOS — `Foundation.Process` är otillgängligt där
    /// (sandboxen tillåter inte att spawna godtyckliga subprocesser).
    /// iOS-appen har bara `fetch(over:)` (SSH-remote) tillgängligt.
    ///
    /// `executableURL`/`arguments` är injicerbara (inte bara ett `binaryName`)
    /// så tester kan peka på ett riktigt, kortlivat skript istället för att
    /// mocka bort själva processkörningen — samma "verifiera mot en riktig
    /// process"-princip som resten av SSHCores tester.
    public static func fetchLocal(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [String] = ["tailscale", "status", "--json"]
    ) throws -> TailscaleStatus {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // stdout och stderr MÅSTE läsas konkurrent, inte sekventiellt: om
        // barnprocessen skriver tillräckligt till stderr för att fylla OS-
        // pipebufferten medan vi fortfarande blockerar i den sekventiella
        // readDataToEndOfFile() på stdout, blockerar barnet i sin tur på
        // write() till stderr — ett klassiskt Process/Pipe-dödläge (ingen
        // sida kan göra framsteg). `tailscale status --json` skriver
        // normalt inget till stderr, men felfallet (t.ex. "not logged in")
        // gör, så den tysta 64KB-gränsen är en verklig risk, inte teoretisk.
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading
        let stdoutThread = ResultThread { stdoutHandle.readDataToEndOfFile() }
        let stderrThread = ResultThread { stderrHandle.readDataToEndOfFile() }
        stdoutThread.start()
        stderrThread.start()
        let data = stdoutThread.join()
        let errData = stderrThread.join()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TailscaleStatusError.localCommandFailed(
                exitCode: process.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? "")
        }
        return try parse(jsonData: data)
    }
    #endif
}

#if canImport(Darwin) || canImport(Glibc)
/// Kör en synkron closure på en egen `Thread` och blockerar tills den är
/// klar — precis vad som krävs för att läsa `stdout`/`stderr` konkurrent
/// i `fetchLocal(executableURL:arguments:)` utan att dela en `var` mellan
/// closures (vilket Swift 6:s strikta datakapplöpningskontroll avvisar).
private final class ResultThread<T>: @unchecked Sendable {
    private let work: () -> T
    private var result: T?
    private let semaphore = DispatchSemaphore(value: 0)

    init(_ work: @escaping () -> T) {
        self.work = work
    }

    func start() {
        Thread { [self] in
            result = work()
            semaphore.signal()
        }.start()
    }

    func join() -> T {
        semaphore.wait()
        return result!
    }
}
#endif
