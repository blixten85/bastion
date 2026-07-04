import Foundation

/// Ett dokumenterat referenskommando i kommandobiblioteket (VISION.md:
/// "Docker, Linux, Git, Cloudflare, Tailscale, WireGuard, systemd — varje
/// kommando med beskrivning, exempel, dokumentation"). Ren, statisk
/// referensdata — ingen persistens, till skillnad från `Snippet` (som
/// användaren sparar/ändrar egna varianter av).
public struct CommandLibraryEntry: Identifiable, Sendable, Equatable {
    public enum Category: String, CaseIterable, Sendable {
        case docker = "Docker"
        case linux = "Linux"
        case git = "Git"
        case cloudflare = "Cloudflare"
        case tailscale = "Tailscale"
        case wireguard = "WireGuard"
        case systemd = "systemd"
    }

    public var id: String { "\(category.rawValue)/\(command)" }
    public let category: Category
    /// Kommandot, ev. med `{{variabler}}` — samma syntax som `Snippet`, kan
    /// återanvända `Snippet(name:template:).rendered(with:)` för ifyllning.
    public let command: String
    public let summary: String
    public let example: String?
    public let docsURL: String?

    public init(category: Category, command: String, summary: String, example: String? = nil, docsURL: String? = nil) {
        self.category = category
        self.command = command
        self.summary = summary
        self.example = example
        self.docsURL = docsURL
    }

    /// Som ett `Snippet` — för att återanvända variabelifyllning/rendering
    /// utan att duplicera den logiken.
    public var asSnippet: Snippet {
        Snippet(name: summary, template: command)
    }
}

/// Det inbyggda kommandobiblioteket. Statiskt (byggs in i appen) — inte
/// tänkt att synas ihop med användarens egna `Snippet`s, men delar samma
/// `{{variabel}}`-rendering.
public enum CommandLibrary {
    public static let all: [CommandLibraryEntry] = [
        // MARK: Docker
        .init(category: .docker, command: "docker ps -a", summary: "Lista alla containrar (även stoppade)"),
        .init(category: .docker, command: "docker compose restart {{service}}", summary: "Starta om en tjänst i Compose-projektet",
              example: "docker compose restart web"),
        .init(category: .docker, command: "docker compose logs -f {{service}}", summary: "Följ loggarna för en tjänst",
              example: "docker compose logs -f web"),
        .init(category: .docker, command: "docker compose pull && docker compose up -d", summary: "Hämta senaste images och uppdatera"),
        .init(category: .docker, command: "docker system df", summary: "Diskanvändning per images/containrar/volymer"),
        .init(category: .docker, command: "docker system prune -af", summary: "Städa bort oanvända images/containrar/nätverk (försiktigt — permanent)"),
        .init(category: .docker, command: "docker exec -it {{container}} sh", summary: "Öppna en shell i en container",
              example: "docker exec -it web sh"),

        // MARK: Linux
        .init(category: .linux, command: "df -h", summary: "Diskutrymme per filsystem, läsbart"),
        .init(category: .linux, command: "du -sh {{path}}/* | sort -rh | head -20", summary: "20 största mapparna/filerna i en katalog",
              example: "du -sh /var/log/* | sort -rh | head -20"),
        .init(category: .linux, command: "journalctl -u {{service}} -f", summary: "Följ loggarna för en systemd-tjänst",
              example: "journalctl -u nginx -f"),
        .init(category: .linux, command: "ss -tlnp", summary: "Lyssnande TCP-portar + vilken process som äger dem"),
        .init(category: .linux, command: "uname -a", summary: "Kernel- och OS-version"),
        .init(category: .linux, command: "free -h", summary: "Minnesanvändning, läsbart"),

        // MARK: Git
        .init(category: .git, command: "git log --oneline -{{n}}", summary: "De {{n}} senaste committen, en rad var",
              example: "git log --oneline -20"),
        .init(category: .git, command: "git fetch --all --prune", summary: "Hämta alla remotes, ta bort borttagna grenar lokalt"),
        .init(category: .git, command: "git branch -vv", summary: "Alla lokala grenar + vilken remote-gren de spårar"),
        .init(category: .git, command: "git diff --stat {{base}}..HEAD", summary: "Vilka filer ändrats sedan en viss punkt",
              example: "git diff --stat main..HEAD"),

        // MARK: Cloudflare
        .init(category: .cloudflare, command: "cloudflared tunnel list", summary: "Lista aktiva Cloudflare-tunnlar på den här maskinen",
              docsURL: "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/"),
        .init(category: .cloudflare, command: "cloudflared tunnel info {{tunnel}}", summary: "Detaljer om en specifik tunnel",
              example: "cloudflared tunnel info mp100"),
        .init(category: .cloudflare, command: "systemctl status cloudflared", summary: "Status för cloudflared-tjänsten"),

        // MARK: Tailscale
        .init(category: .tailscale, command: "tailscale status", summary: "Anslutna noder i Tailscale-nätverket + status",
              docsURL: "https://tailscale.com/kb/1080/cli"),
        .init(category: .tailscale, command: "tailscale ping {{host}}", summary: "Ping över Tailscale-nätverket (visar vilken väg paketet tog)",
              example: "tailscale ping mp100"),
        .init(category: .tailscale, command: "tailscale ip -4", summary: "Den här enhetens Tailscale-IP"),

        // MARK: WireGuard
        .init(category: .wireguard, command: "wg show", summary: "Aktiva WireGuard-interface, peers och senaste handskakning",
              docsURL: "https://www.wireguard.com/quickstart/"),
        .init(category: .wireguard, command: "wg-quick up {{interface}}", summary: "Starta ett WireGuard-interface från dess konfigfil",
              example: "wg-quick up wg0"),
        .init(category: .wireguard, command: "wg-quick down {{interface}}", summary: "Stäng ett WireGuard-interface",
              example: "wg-quick down wg0"),

        // MARK: systemd
        .init(category: .systemd, command: "systemctl status {{service}}", summary: "Status för en tjänst",
              example: "systemctl status docker"),
        .init(category: .systemd, command: "systemctl restart {{service}}", summary: "Starta om en tjänst",
              example: "systemctl restart nginx"),
        .init(category: .systemd, command: "systemctl list-units --failed", summary: "Alla tjänster som för närvarande felar"),
        .init(category: .systemd, command: "systemctl enable --now {{service}}", summary: "Aktivera en tjänst vid uppstart och starta den nu",
              example: "systemctl enable --now docker"),
    ]

    public static func entries(in category: CommandLibraryEntry.Category) -> [CommandLibraryEntry] {
        all.filter { $0.category == category }
    }
}
