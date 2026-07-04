# Roadmap

Status mot [VISION.md](VISION.md). Se [README.md](README.md) för hur man
bygger/kör. Uppdateras löpande i samma PR som ändrar funktionaliteten.

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

## Ännu inte påbörjat (från VISION.md)

Funktioner ur den ursprungliga visionen som inte har någon kod alls än:

- SFTP-filhanterare (Drag & Drop, Zip/Tar, chmod/chown, förhandsvisning, textredigering)
- Inbyggd editor med syntax highlighting
- Snippets med variabler
- Command Library (Docker/Linux/Git/Cloudflare/Tailscale/WireGuard/systemd)
- Plugin-system (Proxmox, TrueNAS, Unraid, Cloudflare, GitHub, Kubernetes)
- ProxyJump, Agent Forwarding, PKCS11, YubiKey, Passkeys
- Face ID/Touch ID + Secure Enclave-bunden nyckellagring (i dag: vanlig Keychain)
- Färgteman/True Color/Ligatures, flera flikar/Split View, musstöd i terminalen
