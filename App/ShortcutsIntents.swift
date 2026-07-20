#if canImport(AppIntents)
import AppIntents
import SSHCore

/// Genvägar/Shortcuts-stöd (App Intents) — gap-listepost #9 i
/// [[project-bastion-termius-parity-mandate]]. Bara Genvägar-halvan av
/// posten: watchOS-stöd är en helt separat plattformsport (eget
/// watchOS-apptarget, egen UI-begränsning) och görs INTE här — den delen
/// av gapet kvarstår medvetet.
///
/// Ingen egen extension-target krävs för grundläggande App Intents/App
/// Shortcuts (till skillnad från t.ex. en Widget eller
/// ASCredentialProviderExtension) — de fungerar direkt inifrån
/// huvudapp-targetet, vilket är varför det här går att implementera och
/// verifiera (kompilerar) utan Xcode-only-arbete utöver det App/ redan är.
///
/// `HostStore()` (utan explicit `path:`) läser den delade `~/.bastion/
/// hosts.json` fristående, inte via någon delad `@Published`-modell — en
/// Genväg körs i sitt eget process-/extension-liknande sammanhang, inte
/// inuti en redan öppen `HostListModel`.
struct HostEntity: AppEntity {
    let id: UUID
    let title: String
    let macAddress: String?

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Bastion-värd"
    static var defaultQuery = HostEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    fileprivate init(_ host: Host) {
        self.id = host.id
        self.title = host.alias.isEmpty ? host.hostName : host.alias
        self.macAddress = host.macAddress
    }
}

struct HostEntityQuery: EntityQuery {
    func entities(for identifiers: [HostEntity.ID]) async throws -> [HostEntity] {
        let store = HostStore()
        let ids = Set(identifiers)
        return store.all().filter { ids.contains($0.id) }.map(HostEntity.init)
    }

    /// Bara värdar med en satt MAC-adress föreslås — resten kan ändå inte
    /// väckas, ingen mening att lista dem i Genvägar-väljaren.
    func suggestedEntities() async throws -> [HostEntity] {
        HostStore().all().filter { $0.macAddress != nil }.map(HostEntity.init)
    }
}

enum ShortcutsError: Error, CustomLocalizedStringResourceConvertible {
    case noMACAddress(String)
    case hostGone

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noMACAddress(let name):
            return "\(name) har ingen MAC-adress sparad — lägg till en i värdens inställningar för att kunna väcka den."
        case .hostGone:
            return "Värden hittades inte längre — kontrollera att den fortfarande finns i din värdlista."
        }
    }
}

struct WakeHostIntent: AppIntent {
    static var title: LocalizedStringResource = "Väck värd (Wake-on-LAN)"
    static var description = IntentDescription(
        "Skickar ett Wake-on-LAN-paket till en sparad Bastion-värd — samma sak som \"Väck\"-åtgärden i värdlistan."
    )

    @Parameter(title: "Värd")
    var host: HostEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Väck \(\.$host)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let full = HostStore().get(host.id) else {
            throw ShortcutsError.hostGone
        }
        guard let mac = full.macAddress else {
            throw ShortcutsError.noMACAddress(host.title)
        }
        try await WakeOnLan.send(mac: mac)
        return .result(dialog: "Skickade Wake-on-LAN till \(host.title).")
    }
}

struct BastionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WakeHostIntent(),
            phrases: [
                "Väck \(\.$host) i \(.applicationName)",
                "Wake on lan \(\.$host) i \(.applicationName)",
            ],
            shortTitle: "Väck värd",
            systemImageName: "bolt.fill"
        )
    }
}
#endif
