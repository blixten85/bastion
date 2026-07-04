# Bastion (arbetsnamn)

Fri, öppen, **fristående** SSH-klient — en app du laddar ner, inte något som
körs i en container. Byggd på [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh)
så att **samma kärna kör på iOS, macOS, Linux och Windows**; bara det tunna
UI-lagret är plattformsspecifikt. All affärslogik ligger i den testade kärnan
(`SSHCore`) — verifierad på Linux, byggbar på Apple.

> "Docker-stöd" = appen hanterar Docker-containrar på dina *fjärrservrar* via SSH.
> Appen själv körs aldrig i en container.

Se [VISION.md](VISION.md) för den fulla visionen (målgrupp, arkitektur,
funktionslista, utvecklingsplan) och [ROADMAP.md](ROADMAP.md) för aktuell
status mot den — den här filen är bara "hur man bygger och kör".

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

## Layout

```
Sources/SSHCore/       Ren SwiftNIO — bygger på Linux OCH Apple
  SSHSession.swift       Anslut, execute() -> AsyncThrowingStream, run(), close()
  SSHUserAuth.swift      Klient-autentisering (lösenord / Ed25519-frö)
  SSHKeyParser.swift     OpenSSH-privatnyckelparser (~/.ssh/id_ed25519)
  SSHShell.swift         Interaktiv PTY-shell: send/resize + strömmad utdata
  ExecHandler.swift      Barnkanal: ByteBuffer <-> SSHChannelData, strömmar utdata
  PortForward.swift      Lokal portvidarebefordran (ssh -L) — direct-tcpip-kanaler
  GlueHandler.swift      Bryggar två Channel-pipelines rakt igenom (från swift-nio-ssh:s exempel)
  HostKeyValidator.swift TOFU-validering + SHA256-fingeravtryck
  KnownHosts.swift       Lagring av sedda värdnycklar (MITM-skydd)
  SSHConfig.swift        ~/.ssh/config-parser (alias, jokertecken, IdentityFile)
  Host.swift             Sparad värd (metadata + taggar, inga hemligheter)
  HostStore.swift        Persistent host-databas (JSON, trådsäker)
  Snippet.swift          Sparat kommando med {{variabler}} + rendering
  SnippetStore.swift     Persistent snippet-databas (JSON, ingen sync ännu)
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
  SnippetListView.swift  Sparade snippets — kör en (fyll i variabler) som startkommando
  SnippetEditView.swift  Lägg till/ändra ett snippet, visar upptäckta {{variabler}} live
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
  SnippetListView.swift  Sparade snippets — motsvarar App/SnippetListView.swift
  SnippetEditView.swift  Lägg till/ändra ett snippet — motsvarar App/SnippetEditView.swift
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

Se [ROADMAP.md](ROADMAP.md) för status, nästa steg och avsiktligt uppskjutna delar.

## Licens

MIT (se `LICENSE`). Alla valda beroenden (SwiftNIO, SwiftNIO SSH, swift-crypto,
SwiftCrossUI, SwiftTerm) är Apache 2.0 / MIT — kompatibla.
