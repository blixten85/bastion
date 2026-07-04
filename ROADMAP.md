# Roadmap

Status mot [VISION.md](VISION.md). Se [README.md](README.md) för hur man
bygger/kör. Uppdateras löpande i samma PR som ändrar funktionaliteten.

## Tekniska avsteg från visionen

VISION.md är bevarad orört som historisk referens — de faktiska valen blev
delvis andra, av konkreta skäl:

| Vision | Faktiskt val | Varför |
|---|---|---|
| SSH: "OpenSSH eller ett välunderhållet bibliotek" | SwiftNIO SSH | Ren Swift, samma kärna på Linux och Apple utan att brygga mot C-OpenSSH |
| Databas: SQLite | JSON (`~/.bastion/hosts.json`) | Host-databasen är liten (taggar + metadata, inga hemligheter) — SQLite vore över­dimensionerat just nu. Kan bytas senare utan att påverka API:t |
| Synk: "iCloud och Git som första alternativ" | Mapp-baserad synk (funkar med iCloud/Dropbox/Syncthing/Git) + OAuth2/PKCE-kontointegration (Dropbox/Google Drive/OneDrive) | Mappmetoden funkar med vilken synktjänst som helst utan extra kod; kontointegration byggd för Dropbox/Google/OneDrive specifikt eftersom de har öppna REST-API:er — iCloud saknar en jämförbar tredjepartsvänlig API utan CloudKit/native-integration (se "Ännu inte påbörjat") |
| Terminalemulering: "en etablerad VT100/xterm-kompatibel motor" | SwiftTerm (Apple), egenskriven VT100/ANSI-tolk (Linux) | SwiftTerm är den etablerade motorn på Apple-sidan. Linux-GUI:t (SwiftCrossUI) har ingen bindning till någon befintlig terminalmotor, så en egen (minimal, testad) tolk skrevs istället |
| — (inget motsvarande i visionen) | Linux-GUI (SwiftCrossUI/GTK4) | Fas 3 (Linux) i visionen nämner ingen specifik teknik — SwiftCrossUI valdes eftersom det är den enda mogna cross-platform Swift-UI-lösningen för Linux |

## Status

| Del | Läge |
|-----|------|
| SSH-transport + handshake | ✅ (NIOSSH) |
| Lösenordsauth | ✅ testad end-to-end |
| Ed25519-auth (rått frö + OpenSSH-nyckelfil) | ✅ testad end-to-end |
| OpenSSH-nyckelfilsparser (`~/.ssh/id_ed25519`, okrypterad) | ✅ testad, autoupptäcks av CLI |
| Krypterad nyckel (lösenfras) + RSA/ECDSA | ⬜ nästa steg (kastar tydligt fel nu) |
| Exec + strömmad stdout/stderr | ✅ testad |
| Exitkod-hantering | ✅ |
| Misslyckad auth utan att hänga | ✅ testad |
| Interaktiv shell + PTY (stdin/stdout, resize) | ✅ testad end-to-end |
| known_hosts / TOFU (SHA256-fingeravtryck, MITM-skydd) | ✅ testad, `~/.bastion/known_hosts` |
| ssh-config-parsing (`Host`-alias, jokertecken, `IdentityFile`) | ✅ testad, CLI slår upp alias |
| Host-databas (JSON, taggar, CRUD) | ✅ testad, `~/.bastion/hosts.json` |
| Dashboard-data (last/minne/disk/uptime/OS/Docker via SSH) | ✅ parser testad, ett kommando |
| Docker-åtgärder (lista/start/stopp/omstart/logg) | ✅ testad, injektionssäker referens |
| Sync mellan enheter (LWW-merge + gravstenar, mapp-transport) | ✅ testad, konvergens bevisad |
| E2E-krypterad sync (AES-256-GCM + PBKDF2, testvektorer) | ✅ testad, chiffertext läcker inget |
| Importera `~/.ssh/config` → host-DB | ✅ testad (parser + dedup) |
| Docker-shell-kommando (`docker exec -it`, injektionssäkert) | ✅ testad |
| Kontoinloggning (OAuth2 + PKCE, Dropbox/Google Drive/OneDrive) | ✅ PKCE-kärna testad mot RFC 7636; alla tre `SyncProvider`-implementationer klara, kräver eget klient-ID (se README "Konton") |
| iOS-app (host-lista, dashboard, Docker+shell, sync, import) | 🧩 `App/`, byggs i Xcode via XcodeGen |
| SwiftTerm-terminalvy | 🧩 `App/TerminalView.swift`, byggs i Xcode |
| macOS-target | ✅ `Bastion-macOS` i `project.yml`, `Platform.swift` bär plattformsskillnaderna, `TerminalView` villkorad på `UIViewRepresentable`/`NSViewRepresentable` |
| Nyckelimport i appen (Keychain) | 🧩 `HostEditView` klistra-in + validering, `HostAuth.keychainKey`, städas vid borttagning |
| Auto-poll av dashboard | 🧩 `DashboardModel.startPolling()`, 15 s intervall, behåller data vid övergående fel |
| App-ikon + launch screen | ✅ `App/Assets.xcassets` |
| Linux-GUI (`bastion-gui`, SwiftCrossUI/GTK4) | ✅ byggd och körd (Xvfb) + egen CI-lane (`linux-gui.yml`, required check) |
| Linux-terminal (VT100/ANSI-tolk, bestående PTY-shell) | ✅ 17 fristående parser-tester gröna, körd (Xvfb) — radvis input (ingen rå key-API i SwiftCrossUI) |
| Linux-Docker-hantering (`DockerView`) | ✅ lista/start/stopp/omstart/logg/shell — motsvarar `App/DockerView.swift` |

## Nästa steg (i ordning)

1. **Verifiera kontointegrationen i Xcode** — `OAuthAccountManager` och alla tre
   `SyncProvider`-implementationerna (Dropbox/Google Drive/OneDrive) är skrivna
   men aldrig byggda (Xcode-only, kan inte kompileras på Linux). Kräver ett
   registrerat klient-ID per leverantör (se README "Konton") för att testas på riktigt.
2. **Få appen på en riktig iPhone** — ingen Mac tillgänglig, så det kräver antingen
   ett Apple Developer-konto (TestFlight via CI) eller en lånad Mac för en
   gratis 7-dagars sideload.
3. Windows-GUI via `WinUIBackend` — otestad, ingen Windows-miljö tillgänglig här.
4. Riktig rå tangentbordsinmatning i Linux-terminalen (kräver att gå under
   SwiftCrossUI mot GTK:s event-controllers direkt — se "Uppskjutet med avsikt").

## Klart

- **App-ikon + launch screen**: `App/Assets.xcassets` (genererad från en SVG med
  `rsvg-convert`, opak PNG utan alfakanal enligt Apples krav — alla iOS- och
  macOS-storlekar) + en mörk `LaunchBackground`-färg som matchar ikonen.
  `ASSETCATALOG_COMPILER_APPICON_NAME` satt i `project.yml` för båda targeten.
- **macOS-target**: `Bastion-macOS` i `project.yml` (App Sandbox + utgående nätverk),
  terminalvyn plattformsvillkorad (`UIViewRepresentable`/`NSViewRepresentable`),
  app-guards `canImport(SwiftUI)`, `typealias Host = SSHCore.Host` i `Platform.swift`
  (undviker krock med `Foundation.Host` på macOS).
- **Auto-poll av dashboard**: `DashboardModel.startPolling()` hämtar direkt och
  sedan var 15:e sekund tills vyn stängs (`.task`-avbrott). Övergående fel under
  en periodisk uppdatering ersätter inte redan visad data — bara den första
  hämtningen kan visa felskärmen. UI visar senaste uppdateringstid + spinner.
- **Nyckelimport i appen**: `HostEditView` har ett "Importera nyckel"-läge —
  klistra in en OpenSSH-privatnyckel, den valideras direkt (`OpenSSHPrivateKey.parse`)
  och sparas i Keychain (aldrig i host-DB:n som synkas). Ny `HostAuth.keychainKey(id)`,
  löses upp i `AuthResolver`. Städas ur Keychain när värden tas bort eller
  auth-metoden byts bort.
- **Linux-GUI** (`bastion-gui`, SwiftCrossUI/GTK4): värdlista, dashboard med
  auto-poll, nyckelfil/lösenord/agent-auth, ssh-config-import.
  Byggd och startad (Xvfb) med en Swift 6.5-dev-snapshot — se README
  "Bygg Linux-GUI:t" för varför stabila 6.1.3 inte funkar än.
- **Linux-terminal** (`TerminalBuffer`/`TerminalGridView`/`TerminalSessionView`):
  bestående PTY-shell (miljö/cwd bevaras mellan kommandon, olikt engångs-`execute()`)
  med en egenskriven VT100/ANSI-tolk — markörflytt (CUU/CUD/CUF/CUB/CUP), radering
  (ED/EL), SGR-färg (16-färgspalett + bold), OSC-sekvenser (fönstertitel) sväljs
  utan att synas. 17 fristående tester (utan SwiftCrossUI-länkning) verifierar
  parsern, inklusive en verklig bugg som hittades under verifieringen: Swift
  grupperar `"\r\n"` till EN grafemkluster-`Character`, så tolkning måste ske
  per `Unicode.Scalar`, inte per `Character` — annars matchar CR/LF aldrig.
  SwiftCrossUI saknar rå tangentbords-API, så inmatning är radvis via
  `TextField` + Enter; piltangenter/Home/End/PgUp/PgDn/Tab/Esc/Ctrl+C/Ctrl+D
  finns som knappar och skickas som rå bytes direkt (navigering i t.ex.
  `htop`/`less` fungerar, löpande texttangenttryckning gör det inte). Fast
  100×30 storlek — ingen fönsterstorleks-driven `resize()` mot PTY:n än.
- **Linux-Docker-hantering**: `DockerView` (i `HostDetailView` via en knapp/sheet)
  lista/start/stopp/omstart/logg/shell — samma `DockerService` som iOS-appen.
  Shell öppnar en `TerminalSessionView` med `docker exec` som initialt kommando
  (nytt `initialCommand`-stöd i `TerminalController`).
- **Kontointegration, PKCE-kärna + Dropbox/Google Drive/OneDrive**: `OAuthPKCE`
  (SSHCore, plattformsoberoende) genererar verifier/challenge enligt RFC 7636
  — testad mot RFC:ns egen vektor (fångade ett eget transkriptionsfel i testet
  självt: `dbjftJeZ…` vs. rätta `dBjftJeZ…`, versalskillnad). `OAuthAccountManager`
  sköter den interaktiva inloggningen (`ASWebAuthenticationSession`),
  `OAuthTokenStore` Keychain-lagring + tyst förnyelse via `refresh_token`.
  Tre färdiga `SyncProvider`-implementationer (samma `SyncCrypto`-kryptering
  som `EncryptedFolderSyncProvider` — molntjänsten ser bara chiffertext):
  Dropbox (path-baserad), OneDrive (path-baserad via Graph), Google Drive
  (sök-först + multipart-upload mot `appDataFolder`, ingen path-API där).
  `SyncSettingsView` har transportval (mapp/Dropbox/Google Drive/OneDrive) +
  in-/utloggning per leverantör. **OBS**: allt utom PKCE-kärnan är Xcode-only
  och därför obyggt/otestat här — kräver ett riktigt klient-ID per leverantör
  (se README "Konton") för att verifieras.
- **Golden standard-repokonfiguration**: LICENSE (MIT), SECURITY.md, AGENTS.md,
  CLAUDE.md, PR/issue-mallar, standardworkflows (auto-commit/label/merge/rebase/release,
  ci-autofix, copilot-review-reminder, security-alerts-sync), branch-ruleset på
  `main` med tre required checks (App/, SSHCore, LinuxApp).

## Uppskjutet med avsikt

- **Krypterade nycklar (lösenfras) + RSA/ECDSA.** OpenSSH krypterar med
  `bcrypt_pbkdf` (Blowfish-baserad) + `aes256-ctr`. Varken bcrypt_pbkdf eller
  AES-CTR finns i swift-cryptos publika API, så det kräver egna implementationer
  av Blowfish + bcrypt_pbkdf + AES-CTR — säkerhetskritisk kod som förtjänar en
  egen genomgång med testvektorer, inte en snabb iteration. Parsern kastar
  `SSHKeyError.encrypted` tydligt tills dess.
- **Rå tangentbordsinmatning i Linux-terminalen.** SwiftCrossUI har ingen
  key-event-API alls. En riktigt interaktiv terminal (piltangenter/Ctrl+C
  live, som SwiftTerm) skulle kräva en egen Cairo-ritad GTK-widget med GTK:s
  event-controllers direkt, utanför SwiftCrossUIs `View`-träd — större jobb,
  och kräver en osäker generisk-till-konkret cast (`GtkBackend.Widget` är
  faktiskt `Gtk.Widget`, så det är tekniskt möjligt men inte en ren, stödd
  API-väg). Radvis input + kontrollknappar täcker det mesta (se "Klart" ovan)
  tills vidare.

Interaktiv shell finns i kärnan (`SSHSession.openShell`) och driver både
`App/TerminalView.swift` (SwiftTerm) och `LinuxApp`s `TerminalSessionView`.

## Backlog, fasindelad (uppdaterad 2026-07-04 efter konkurrentanalys)

Se [VISION.md](VISION.md) "Tillägg efter den ursprungliga visionen" för
bakgrunden (konkurrentlandskap: Termius/Tabby/Termix/Magic Term/Conduit).
Strategin: UX-paritet med Termius väger tyngre än nya SSH-protokollfunktioner
för sin egen skull — det är UX:en folk betalar för, inte protokollet.

**Juridiskt:** undvik visuell/varumärkeslikhet med Termius i design — se
VISION.md "Design".

### Fas A — Få ut det som redan är byggt
Inget nytt att bygga, bara verifiera/lansera:
- Verifiera kontointegrationen i Xcode (Dropbox/Google Drive/OneDrive) med
  ett riktigt klient-ID.
- Få appen på en riktig iPhone (Apple Developer-konto för TestFlight, eller
  en lånad Mac för en gratis 7-dagars sideload).

### Fas B — UX-paritet med Termius (det folk betalar för idag)
- **Port Forwarding**: 🧩 **lokal (`-L`) klar i SSHCore** —
  `SSHSession.openLocalPortForward(bindHost:bindPort:targetHost:targetPort:)`,
  en lokal TCP-lyssnare som bryggar varje ansluten klient till en egen
  `direct-tcpip`-SSH-kanal (`GlueHandler`, kopierad från swift-nio-ssh:s eget
  exempel — inte del av det publika biblioteket). Testad end-to-end mot
  loopback-testservern (riktig TCP-socket → SSH-kanal → eko → tillbaka).
  **Kvar**: fjärr (`-R`) och dynamisk (`-D`, SOCKS) inte påbörjat; ingen
  CLI-/UI-koppling än (varken `bastion-cli`, App/ eller LinuxApp) — kärnan
  går att anropa programmatiskt men har ingen yta att starta/stoppa en
  tunnel från än.
- **Face ID/Touch ID-app-lås** — Keychain finns redan för hemligheter, men
  inget lager som låser SJÄLVA appen vid start/bakgrund.
- **Snippets med variabler** — ✅ klart, både App/ och LinuxApp. `Snippet`/
  `SnippetStore` i SSHCore (`{{namn}}`-variabler, testat inkl. en fångad
  regression: extraherad variabel trimmades men ersättningen letade efter
  den otrimmade nyckeln, så `{{ mellanslag }}` aldrig matchade). UI: knapp
  i värddetaljvyn, fyll i variabler, kör som startkommando i en ny terminal
  (samma `ConnectRequest.running(_:)`/`initialCommand`-mönster som Docker-
  shell). Ingen sync av snippets mellan enheter än (medvetet, v1).
- **Favoriter/färgkodning i host-listan** — ✅ klart, både App/ (`Host.isFavorite`/
  `colorTag` i SSHCore, `HostColorPicker`, egen "★ Favoriter"-sektion) och
  LinuxApp (samma fält, favoriter sorterade överst, "☆/★ Favorit"-knapp
  eftersom SwiftCrossUI saknar swipe-actions).
- **Sök i host-listan** — ✅ klart, både LinuxApp (`ContentView.swift`) och
  App/ (`HostListView.swift`, native `.searchable()`). Filtrerar alias/
  hostname/user/taggar i båda.
- **Flera samtidiga sessioner / Split View** — appen hanterar en session åt
  gången idag.

### Fas C — Differentiatorer bortom Termius
- Docker-hantering ✅ redan klart (App + LinuxApp).
- Systemstatus/dashboard ✅ redan klart.
- **Tailscale-stöd** (nytt, från konkurrentanalysen) — inte påbörjat.
- **WireGuard-profiler** (nytt) — inte påbörjat.
- **Command Library** (Docker/Linux/Git/Cloudflare/Tailscale/WireGuard/
  systemd, med beskrivning/exempel/dokumentation per kommando) — inte påbörjat.

### Fas D — De stora bitarna (ingen ändring i prioritet)
- SFTP-filhanterare (Drag & Drop, Zip/Tar, chmod/chown, förhandsvisning, textredigering)
- Inbyggd editor med syntax highlighting
- Plugin-system (Proxmox, TrueNAS, Unraid, Cloudflare, GitHub, Kubernetes)
- ProxyJump, Agent Forwarding, PKCS11, YubiKey, Passkeys
- Secure Enclave-bunden nyckellagring (i dag: vanlig Keychain)
- Färgteman/True Color/Ligatures, musstöd i terminalen
