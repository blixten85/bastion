# Bastion (arbetsnamn)

Fri, öppen, **fristående** SSH-klient — en app du laddar ner, inte något som
körs i en container. Byggd på [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh)
så att **samma kärna kör på iOS, macOS, Linux och Windows**; bara det tunna
UI-lagret är plattformsspecifikt. All affärslogik ligger i den testade kärnan
(`SSHCore`) — verifierad på Linux, byggbar på Apple.

> "Docker-stöd" = appen hanterar Docker-containrar på dina *fjärrservrar* via SSH.
> Appen själv körs aldrig i en container.

## Cross-platform & sync

| Plattform | Kärna | UI |
|-----------|-------|----|
| iOS/iPadOS | ✅ | SwiftUI (`App/`) — fas 1 |
| macOS | ✅ | SwiftUI (delas med iOS) |
| Linux | ✅ (byggd/testad här) | CLI + GUI (SwiftCrossUI/GTK4) — se toolchain-kravet nedan |
| Windows | ✅ (Swift finns på Windows) | GUI senare (WinUIBackend, otestad) |

**Sync utan inloggning:** host-databasen slås ihop deterministiskt mellan enheter
(`SyncEngine`, last-write-wins + gravstenar för raderingar). Transporten är en
enkel fil i en synkad mapp (`FolderSyncProvider`) — peka på iCloud Drive, Dropbox,
Syncthing eller en Git-mapp. Ingen server, inget konto.

**End-to-end-krypterat:** `EncryptedFolderSyncProvider` krypterar hela nyttolasten
på enheten med **AES-256-GCM**, nyckel härledd ur en lösenfras via
**PBKDF2-HMAC-SHA256** (verifierad mot kända testvektorer). Molntjänsten ser bara
chiffertext; fel lösenfras eller manipulerad fil upptäcks och avvisas. Så oavsett
om filen ligger i Dropbox, Google Drive, OneDrive eller iCloud är innehållet
oläsbart för alla utom dina enheter.

### Konton (Dropbox/Google/OneDrive/iCloud)
Två vägar, och de utesluter inte varandra:
1. **Synkad mapp (finns nu):** peka på en mapp som tjänstens egen app redan synkar
   (iCloud Drive, Dropbox, Syncthing, Git). Inget OAuth i appen, funkar direkt.
2. **Kontointegration (Dropbox klar, Google/OneDrive samma mönster):** logga in
   mot Dropbox via OAuth2 + PKCE (`ASWebAuthenticationSession`) och skriv filen
   direkt via deras API, mot en app-scopad mapp (aldrig hela kontot).

iCloud har ingen egen kod än — det fungerar redan i dag via väg 1 (peka
"Synkad mapp" på iCloud Drive-mappen), men kräver att användaren själv hittar
och pekar ut den. En native CloudKit/ubiquity-container-integration (slipper
peka ut mappen manuellt) är en möjlig framtida förbättring, inte byggd.

Oavsett väg är nyttolasten E2E-krypterad, så leverantören är bara dum lagring.

**Vill du använda kontoinloggning?** Klientkoden är klar för alla tre — Dropbox,
Google Drive, OneDrive — men kräver att DU registrerar en app hos leverantören;
det kan inte kodas i förväg:

| Leverantör | Utvecklarkonsol | Scope | Redirect URI |
|---|---|---|---|
| Dropbox | [App Console](https://www.dropbox.com/developers/apps) | `files.content.write` + `files.content.read` (App folder) | `se.denied.bastion://oauth/dropbox` |
| Google Drive | [Cloud Console](https://console.cloud.google.com/apis/credentials) | `drive.appdata` | `se.denied.bastion://oauth/googledrive` |
| OneDrive | [Azure-portalen (App registrations)](https://portal.azure.com) | `Files.ReadWrite.AppFolder offline_access` | `se.denied.bastion://oauth/onedrive` |

Klistra in respektive klient-ID i `App/OAuthProviders.swift` (t.ex.
`OAuthProviders.dropbox.clientID`) — inget annat behöver ändras.

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
| Kontoinloggning (OAuth2 + PKCE, Dropbox/Google Drive/OneDrive) | ✅ PKCE-kärna testad mot RFC 7636; alla tre `SyncProvider`-implementationer klara, kräver eget klient-ID (se "Konton") |
| iOS-app (host-lista, dashboard, Docker+shell, sync, import) | 🧩 `App/`, byggs i Xcode via XcodeGen |
| SwiftTerm-terminalvy | 🧩 `App/TerminalView.swift`, byggs i Xcode |
| macOS-target | ✅ `Bastion-macOS` i `project.yml`, `Platform.swift` bär plattformsskillnaderna, `TerminalView` villkorad på `UIViewRepresentable`/`NSViewRepresentable` |
| Nyckelimport i appen (Keychain) | 🧩 `HostEditView` klistra-in + validering, `HostAuth.keychainKey`, städas vid borttagning |
| Auto-poll av dashboard | 🧩 `DashboardModel.startPolling()`, 15 s intervall, behåller data vid övergående fel |
| Linux-GUI (`bastion-gui`, SwiftCrossUI/GTK4) | ✅ byggd och körd (Xvfb) + egen CI-lane (`linux-gui.yml`, required check) |
| Linux-terminal (VT100/ANSI-tolk, bestående PTY-shell) | ✅ 17 fristående parser-tester gröna, körd (Xvfb) — radvis input (ingen rå key-API i SwiftCrossUI) |
| Linux-Docker-hantering (`DockerView`) | ✅ lista/start/stopp/omstart/logg/shell — motsvarar `App/DockerView.swift` |

## Layout

```
Sources/SSHCore/       Ren SwiftNIO — bygger på Linux OCH Apple
  SSHSession.swift       Anslut, execute() -> AsyncThrowingStream, run(), close()
  SSHUserAuth.swift      Klient-autentisering (lösenord / Ed25519-frö)
  SSHKeyParser.swift     OpenSSH-privatnyckelparser (~/.ssh/id_ed25519)
  SSHShell.swift         Interaktiv PTY-shell: send/resize + strömmad utdata
  ExecHandler.swift      Barnkanal: ByteBuffer <-> SSHChannelData, strömmar utdata
  HostKeyValidator.swift TOFU-validering + SHA256-fingeravtryck
  KnownHosts.swift       Lagring av sedda värdnycklar (MITM-skydd)
  SSHConfig.swift        ~/.ssh/config-parser (alias, jokertecken, IdentityFile)
  Host.swift             Sparad värd (metadata + taggar, inga hemligheter)
  HostStore.swift        Persistent host-databas (JSON, trådsäker)
  SystemProbe.swift      Dashboard: ett SSH-kommando -> SystemSnapshot (parser testad)
  DockerService.swift    Docker: lista/start/stopp/omstart/logg (injektionssäkert)
  SyncEngine.swift       Deterministisk merge (LWW + gravstenar) för sync
  SyncProvider.swift     Synktransport (mapp/iCloud/Dropbox/Syncthing/Git)
  SyncCrypto.swift       E2E-kryptering (AES-256-GCM + PBKDF2) + krypterad provider
  OAuthPKCE.swift        PKCE-kärna (RFC 7636) för kontointegration — testad, plattformsoberoende
  SSHTypes.swift         SSHTarget, SSHAuth, SSHChunk, SSHError, HostKeyInfo
Sources/bastion-cli/   Tunn CLI runt SSHCore (bevisar mot riktig server)
Tests/SSHCoreTests/    In-process SSH-server + end-to-end-test (ingen extern server)
App/                   XCODE-ONLY: iOS+macOS-appen (SwiftUI, delad kod) + XcodeGen-spec
  project.yml            XcodeGen → Bastion.xcodeproj (targets: Bastion iOS, Bastion-macOS)
  Platform.swift         Plattformsskillnader iOS/macOS samlade (Host-alias, nav-hjälpare)
  BastionApp.swift       @main
  HostListView.swift     Värdlista grupperad på tagg, anslut/redigera/ta bort
  HostEditView.swift     Lägg till / ändra värd
  HostDetailView.swift   Dashboard vid öppning + knapp till terminal
  DashboardView.swift    Renderar SystemSnapshot (last, minne, disk, Docker)
  DockerView.swift       Containerlista med start/stopp/omstart/logg/shell
  SessionView.swift      Aktiv session → terminalvyn (valfritt startkommando)
  TerminalView.swift     SwiftTerm kopplad till SSHCore.SSHShell (UIViewRepresentable/NSViewRepresentable)
  AuthResolver.swift     Delad SSHAuth-uppbyggnad
  Keychain.swift         Hemligheter (sync-lösenfras) i Keychain
  SyncSettingsView.swift Synkmapp/molnval, lösenfras, in/utloggning, "Synka nu"
  ImportConfigView.swift Klistra in ssh-config för att importera värdar
  OAuthProviders.swift   Dropbox/Google/OneDrive-config (klient-ID tomt tills du fyller i det)
  OAuthToken.swift       Token-modell (access/refresh/utgång)
  OAuthTokenStore.swift  Keychain-lagring + tyst förnyelse (inte MainActor — anropas synkront)
  OAuthAccountManager.swift Interaktiv PKCE-inloggning (ASWebAuthenticationSession) — OBS ej byggd här
  DropboxSyncProvider.swift SyncProvider mot Dropbox (krypterat, som EncryptedFolderSyncProvider)
  GoogleDriveSyncProvider.swift SyncProvider mot Google Drive (appDataFolder, sök+multipart-upload)
  OneDriveSyncProvider.swift    SyncProvider mot OneDrive (Graph API, path-baserad som Dropbox)
  Info.plist             Endast iOS-target (macOS genererar sin egen Info.plist)
LinuxApp/              EGET SwiftPM-paket (se "Bygg Linux-GUI:t" — varför det inte ligger i rot-paketet)
  Package.swift          .package(path: "..") mot roten för SSHCore, + SwiftCrossUI
  Sources/bastion-gui/   Linux-GUI, SwiftCrossUI (GTK4)
  BastionGUIApp.swift    @main, beror på GtkBackend direkt (se kommentar i Package.swift)
  ContentView.swift      NavigationSplitView: värdlista + dashboard/kommando
  HostListModel.swift    Host-databas-wrapper (samma HostStore som App/)
  HostEditView.swift     Lägg till/ändra värd — agent/lösenord/nyckelfil (ingen Keychain här)
  ImportConfigView.swift Klistra in ssh-config för import
  HostDetailView.swift   Lösenordsgrind + dashboard + terminal för vald värd
  DashboardView.swift    Samma auto-poll-modell som App/, SwiftCrossUI-vyer
  TerminalBuffer.swift   Egen VT100/ANSI-tolk (markör, SGR-färg, radering) — testad, se nedan
  TerminalGridView.swift Renderar buffern som hopslagna Text-körningar (ingen Canvas i SwiftCrossUI)
  TerminalSessionView.swift Bestående PTY-shell + radvis input + kontrollknappar (piltangenter/Home/End/PgUp/PgDn/Ctrl+C/Tab/Esc)
  DockerView.swift       Docker: lista/start/stopp/omstart/logg/shell — motsvarar App/DockerView.swift
  AuthResolver.swift     Som App/, men `.keychainKey` ger nil (ingen Keychain på Linux)
```

## Bygga & testa (Linux eller macOS)

```sh
swift build
swift test
```

Testerna startar en riktig SSH-server i processen på en slumpport och kör hela
klientvägen mot den — ingen extern server eller några hemligheter krävs.

## Kör mot en riktig server

```sh
swift build
BASTION_PASSWORD='...' ./.build/debug/bastion-cli user@host:22 "uname -a; docker ps"
# nyckel (rått 32-byte Ed25519-frö som hex):
BASTION_ED25519_HEX='...' ./.build/debug/bastion-cli user@host "systemctl status"
# alias ur ~/.ssh/config (User/HostName/Port/IdentityFile hämtas därifrån):
./.build/debug/bastion-cli myserver "docker ps"
```

Autentiseringsordning i CLI:t: `BASTION_KEY_FILE` > `BASTION_ED25519_HEX` >
`BASTION_PASSWORD` > `IdentityFile` (ssh-config) > `~/.ssh/id_ed25519` > lösenordsfråga.

## Bygg Linux-GUI:t (`bastion-gui`, i `LinuxApp/`)

Eget SwiftPM-paket, medvetet skilt från roten (`.package(path: "..")` för
`SSHCore`) — annars skulle rotens `swift build`/`swift test` dra in hela
SwiftCrossUI-grafen och krascha på stabil toolchain (se nästa stycke).

**Kräver en Swift-toolchain nyare än 6.1.3.** Stabila Swift 6.1.3 (Ubuntus
`apt install swiftlang`) kraschar med ett bekräftat, öppet kompilatorfel
([swiftlang/swift#80759](https://github.com/swiftlang/swift/issues/80759)) när
den bygger SwiftCrossUIs `swift-mutex`-beroende — inget fel i den här koden.
Verifierat löst i en Swift 6.5-dev-snapshot (2026-07-02).

```sh
apt-get install libgtk-4-dev pkg-config   # GTK4-headers, en gång
cd LinuxApp
swift build --product bastion-gui         # med en toolchain där buggen är fixad
./.build/debug/bastion-gui
```

Beror på `GtkBackend` direkt i stället för `DefaultBackend` (se kommentar i
`LinuxApp/Package.swift`) — `DefaultBackend`s plattformsvillkorade
`WinUIBackend`-gren byggdes ändå på en tidig SwiftPM-snapshot och krävde
Windows-headers som saknas på Linux. `GtkBackend` beror bara på
`SwiftCrossUI` + `Gtk` + `CGtk`.

### Om din toolchain-nedladdning är byggd för en äldre Ubuntu-version
En `ubuntu24.04`-snapshot på en nyare Ubuntu (t.ex. 26.04, som saknar
`libxml2.so.2` — bara `libxml2-16`) ger `error while loading shared libraries:
libxml2.so.2`. Lös genom att peka `LD_LIBRARY_PATH` på en mapp med den gamla
`.so`:n (extraherad ur ett arkiverat `libxml2`-paket, aldrig `dpkg`-installerad
systemvitt):

```sh
LD_LIBRARY_PATH=/path/to/compat-libs swift build --product bastion-gui
```

## Bygg appen (på en Mac)

`App/project.yml` genererar **två** Xcode-mål ur samma delade SwiftUI-kod:
`Bastion` (iOS, fas 1) och `Bastion-macOS` (fas 2, App Sandbox + utgående
nätverk). Xcode-projektet genereras med [XcodeGen](https://github.com/yonaskolb/XcodeGen)
— så projektet hålls i textform och kan versionshanteras.

```sh
brew install xcodegen
cd App
xcodegen generate
open Bastion.xcodeproj
```

I Xcode: välj ditt team under **Signing & Capabilities**, välj target (`Bastion`
eller `Bastion-macOS`) och kör på simulator/enhet eller Mac. SwiftTerm och
SSHCore dras in automatiskt som paketberoenden till båda targeten.

### Väg till App Store
1. Byt `PRODUCT_BUNDLE_IDENTIFIER` i `project.yml` till ditt eget (t.ex. `se.dittnamn.bastion`).
2. Sätt signeringsteam (app-ikon och launch screen finns redan, se `Assets.xcassets`).
3. Höj `MARKETING_VERSION`, arkivera (**Product → Archive**) och ladda upp via Organizer.
4. Öppen källkod-appar godkänns — se bara till att licens (MIT/Apache) och ev.
   tredjepartslicenser (SwiftNIO, SwiftTerm) listas i appen.

Appens affärslogik ligger i den testade kärnan (`SSHCore`); `App/`-lagret är tunn
SwiftUI-glue. Så länge kärnan är grön är appen mest layout att putsa i Xcode.

## Terminalvyn (Xcode)

`App/TerminalView.swift` kopplar `SSHCore.SSHSession` till
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). Lägg till SwiftTerm som
paketberoende i ett Xcode-app-target — den byggs inte av SwiftPM på Linux (kräver
UIKit/AppKit). En interaktiv shell använder en PTY-kanal (backlog); vyn visar
exec-utdata idag för att bevisa datavägen till skärmen.

## Nästa steg (i ordning)

1. **Verifiera kontointegrationen i Xcode** — `OAuthAccountManager` och alla tre
   `SyncProvider`-implementationerna (Dropbox/Google Drive/OneDrive) är skrivna
   men aldrig byggda (Xcode-only, kan inte kompileras på Linux). Kräver ett
   registrerat klient-ID per leverantör (se "Konton" ovan) för att testas på riktigt.
2. Windows-GUI via `WinUIBackend` — otestad, ingen Windows-miljö tillgänglig här.
3. Riktig rå tangentbordsinmatning i Linux-terminalen (kräver att gå under
   SwiftCrossUI mot GTK:s event-controllers direkt — se "Uppskjutet med avsikt").

### Klart
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
  Byggd och startad (Xvfb) med en Swift 6.5-dev-snapshot — se "Bygg Linux-GUI:t"
  ovan för varför stabila 6.1.3 inte funkar än.
- **Linux-terminal** (`TerminalBuffer`/`TerminalGridView`/`TerminalSessionView`):
  bestående PTY-shell (miljö/cwd bevaras mellan kommandon, olikt engångs-`execute()`)
  med en egenskriven VT100/ANSI-tolk — markörflytt (CUU/CUD/CUF/CUB/CUP), radering
  (ED/EL), SGR-färg (16-färgspalett + bold), OSC-sekvenser (fönstertitel) sväljs
  utan att synas. 17 fristående tester (utan SwiftCrossUI-länkning) verifierar
  parsern, inklusive en verklig bugg som hittades under verifieringen: Swift
  grupperar `"\r\n"` till EN grafemkluster-`Character`, så tolkning måste ske
  per `Unicode.Scalar`, inte per `Character` — annars matchar CR/LF aldrig.
  SwiftCrossUI saknar rå tangentbords-API, så inmatning är radvis via
  `TextField` + Enter; piltangenter/Tab/Esc/Ctrl+C/Ctrl+D finns som knappar och
  skickas som rå bytes direkt (navigering i t.ex. `htop`/`less` fungerar,
  löpande texttangenttryckning gör det inte). Fast 100×30 storlek — ingen
  fönsterstorleks-driven `resize()` mot PTY:n än.
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
  (se "Konton" ovan) för att verifieras.

### Uppskjutet med avsikt
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
  och strukturellt oklart hur den skulle hänga in i trädet. Radvis input +
  kontrollknappar täcker det mesta (se "Klart" ovan) tills vidare.

Interaktiv shell finns i kärnan (`SSHSession.openShell`) och driver både
`App/TerminalView.swift` (SwiftTerm) och `LinuxApp`s `TerminalSessionView`.

## Licens

MIT (se `LICENSE`). Alla valda beroenden (SwiftNIO, SwiftNIO SSH, swift-crypto,
SwiftCrossUI, SwiftTerm) är Apache 2.0 / MIT — kompatibla.
