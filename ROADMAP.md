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
2. **Få appen på en riktig iPhone** — 🧩 påbörjad, 2026-07-06. Apple Developer
   Program köpt och ID-verifiering inskickad (väntar på att kontot blir
   aktivt). CI-vägen förberedd medan verifieringen pågår: `.github/workflows/
   testflight.yml` (manuell knapp) + `App/fastlane/Fastfile` bygger, signerar
   helt automatiskt (App Store Connect API-nyckel, inget manuellt certifikat/
   provisioning profile) och laddar upp till TestFlight — ingen lokal Mac
   behövs. Se README "TestFlight utan en egen Mac" för de fyra secrets som
   behöver sättas när kontot är aktivt. Ruby-/fastlane-syntaxen är verifierad
   (`ruby -c`), men aldrig körd på riktigt än — kräver macOS-runnern +
   riktiga nycklar för det sista beviset.
3. **Windows-GUI via `WinUIBackend`** — påbörjad och blockerad av två
   bekräftade uppströmsbuggar, inte något i Bastions egen kod. `WindowsApp/`
   (eget SwiftPM-paket, samma mönster som `LinuxApp/`) byggs på en riktig
   Windows Server 2025-VPS (2026-07-06, Swift 6.1-RELEASE + VS 2026 Build
   Tools installerade manuellt för att matcha `.github/workflows/
   windows-gui.yml` exakt) — samma två fel som i CI, nu bekräftade på
   riktig hårdvara, inte bara `windows-latest`-runnern:
   1. `NIOThread.handle: NIOLockedValueBox<ThreadOpsSystem.ThreadHandle?>`
      (`ThreadWindows.swift`) kan inte konformera till `Sendable` under
      Swift 6.1:s strikta concurrency, eftersom `UnsafeMutableRawPointer`
      har `Sendable`-konformansen explicit omarkerad `unavailable` i
      standardbiblioteket. Känt, fortfarande öppet uppströms-fel:
      `apple/swift-nio#2065` (dubbelbekräftat av en separat duplikat-issue
      `#3460`).
   2. **Nytt fynd** (upptäckt på riktig hårdvara, syntes inte tydligt i
      CI-loggarna tidigare): `System.swift:572` —
      `static let SOL_UDP: CInt = CInt(IPPROTO_UDP)` — `IPPROTO` konformerar
      inte till `BinaryFloatingPoint`, en typmismatch i swift-nios egen
      Windows-portering av POSIX-konstanterna. Inte undersökt vidare ännu
      om det redan finns en uppströms-issue för det.
   Ingen av dessa går att fixa i Bastions egen kod utan att forka swift-nio.
   `windowsapp-build` är inte en required check av precis den anledningen.
   Nästa steg när/om uppströms fixar detta: porta de riktiga vyerna från
   `LinuxApp/Sources/bastion-gui/` hit och testa på riktigt på VPS:n.
4. Riktig rå tangentbordsinmatning i Linux-terminalen (kräver att gå under
   SwiftCrossUI mot GTK:s event-controllers direkt — se "Uppskjutet med avsikt").

## Klart

- **Nyckelgenerering + export + fjärr-deploy till authorized_keys** (2026-07-06,
  `KeyManagement.swift`/`SSHKeyParser.swift`): kärnan för ett fullständigt
  "generera-nyckel-och-byt-bort-lösenord"-flöde.
  - `KeyGenerator.generateEd25519(comment:)` — ett helt nytt, slumpmässigt
    Ed25519-nyckelpar (`Curve25519.Signing.PrivateKey()`, samma
    `NIOSSHPrivateKey`-inpackning som redan användes för host-nycklar).
  - `OpenSSHPrivateKey.export(seed:comment:)` — skriver en okrypterad
    Ed25519-nyckel i riktigt OpenSSH-filformat (samma format `ssh-keygen`
    skapar), inversen av den redan befintliga `parse`-funktionen. Verifierad
    dubbelt: rundresa genom den egna (redan bevisade) decodern, OCH ett
    riktigt `ssh-keygen -y -f`-anrop mot den exporterade filen — den faktiska,
    kanoniska implementationen läser vår fil och räknar ut exakt samma
    publika nyckel, inte bara vår egen kod som testar sig själv.
  - `SSHSession.deployPublicKey(_:)` — lägger till en publik nyckelrad i
    fjärrsidans `~/.ssh/authorized_keys` över en redan autentiserad session
    (idempotent: `mkdir -p`/`chmod`/`grep -qxF || echo >>`, aldrig
    dubblettrader). Kommentaren (fri text) är inte ett smalt validerbart
    format som `DockerService`s namn-allowlist, så en riktig `shellQuoted`-
    escaping används istället — testad mot en RIKTIG `/bin/sh`-subprocess
    (inte bara egen escape-logik mot sig själv), inklusive skalmetatecken
    (`$() \`` ; & | > < \`) och en injektionsförsöks-sträng.
  - `SSHSession.verifyKeyAuthWorks(target:seed:knownHosts:)` — en tyst,
    separat anslutning med den nya nyckeln, stänger direkt utan att köra
    något kommando. Testad end-to-end mot `LoopbackServer` (lyckas) och mot
    en onåbar host (misslyckas rent, ingen hängning).
  - **Windows-stöd** (2026-07-06, `RemotePlatform`): `deployPublicKey(_:platform:)`
    tar nu ett `RemotePlatform`-argument (`.posix` default, `.windowsAdmin`,
    `.windowsStandard`) — upptäckt via RIKTIG verifiering mot en Windows
    Server 2025-VPS att Win32-OpenSSH har en avsiktlig säkerhetsregel:
    admin-konton IGNORERAR `~/.ssh/authorized_keys` helt, kräver den delade
    `C:\ProgramData\ssh\administrators_authorized_keys` med strikta ACL:er
    (`icacls`, bara SYSTEM+Administrators, ärvda rättigheter avstängda) —
    annars vägrar sshd använda filen. Windows-kommandot byggs som ett
    `powershell -EncodedCommand`-anrop (hela skriptet Base64/UTF-16LE-kodat)
    istället för att försöka escapa en fri kommentarsträng genom två
    nästlade skallager (SSH-exec-argumentet OCH cmd.exe/PowerShells egen
    citering) — base64 innehåller bara tecken som är säkra oquotade i cmd.exe.
    **Verifierat mot riktig extern hårdvara, inte bara enhetstester**: hela
    flödet (generera nyckel → `deployPublicKey(platform: .windowsAdmin)` →
    `verifyKeyAuthWorks`) kört i ett svep mot en riktig Windows Server 2025-
    VPS, autentiserade rent utan lösenord. Testnycklarna städades bort
    efteråt.
  - **`Host.platform`-fält** (2026-07-06): ✅ klart. `RemotePlatform`
    (`.posix`/`.windowsAdmin`/`.windowsStandard`) sparas nu per host-profil
    (bakåtkompatibel avkodning — gamla `host.json`-filer utan fältet faller
    tillbaka på `.posix`, samma mönster som `isFavorite`/`colorTag`). Egen
    `Picker` i `LinuxApp/HostEditView.swift` ("Fjärrsystem").
  - **Kvar**: generera/importera/exportera-knappar, "byt ut lösenord mot
    nyckel"-flödet (deploy + tyst verifiering + checkbox/toggle för att ta
    bort lösenordet ur Bastions EGEN lagring, aldrig fjärrserverns faktiska
    auth-konfiguration — se [[feedback_password_removal_scope]] för
    resonemanget) i App/LinuxApp, samt Keychain-borttagningen av det gamla
    lösenordet efter grönt ljus (iOS/macOS-specifikt — LinuxApp har ingen
    Keychain-motsvarighet, se `AuthResolver.swift`).
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

## Backlog, fasindelad (uppdaterad 2026-07-06 — tvOS tillagd)

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
- Få appen på en riktig iPhone — 🧩 påbörjad, se "Nästa steg" ovan (Apple
  Developer Program köpt, CI-vägen förberedd, väntar på kontoverifiering).

### Fas B — UX-paritet med Termius (det folk betalar för idag)
- **Port Forwarding**: 🧩 **lokal (`-L`) OCH fjärr (`-R`) klara i SSHCore**.
  - Lokal: `SSHSession.openLocalPortForward(bindHost:bindPort:targetHost:targetPort:)`,
    en lokal TCP-lyssnare som bryggar varje ansluten klient till en egen
    `direct-tcpip`-SSH-kanal. `close()` stänger både lyssnaren och alla
    aktiva tunnlar (CodeRabbit-fynd, PR #25/#61, se "Klart").
  - Fjärr (2026-07-06): `SSHSession.openRemotePortForward(bindHost:bindPort:targetHost:targetPort:)`
    — ber servern lyssna åt oss (`sendTCPForwardingRequest(.listen(...))`,
    ett globalt SSH-request, inte en kanal). Servern öppnar en
    `forwarded-tcpip`-kanal TILLBAKA till oss för varje anslutning; en
    delad, trådsäker tabell (`SSHSession.remoteForwards`, keyad på port)
    dirigerar varje inkommen kanal till rätt lokal `targetHost:targetPort`
    via `handleInboundForwardedChannel` (satt som `inboundChildChannelInitializer`
    vid `connect()`). Samma `GlueHandler`/`DirectTCPIPWrapperHandler` som
    lokal vidarebefordran, bara i motsatt riktning.
    Testservern (`LoopbackServer`) fick en riktig `GlobalRequestDelegate`-
    implementation (`ServerRemoteForwardingDelegate`/`ServerRemoteForwarder`,
    baserad på swift-nio-ssh:s eget `NIOSSHServer`-exempel) för att kunna
    bevisa hela vägen end-to-end (riktig extern TCP-anslutning → servern →
    SSH → klienten → riktig lokal TCP-ekoserver → samma väg tillbaka), inte
    bara en förenklad eko-kortslutning.
    **3 riktiga buggar hittade under just den här verifieringen** (skulle
    inte synts utan ett genuint end-to-end-test): (1) `DirectTCPIPWrapperHandler`
    sattes på fel kanal i `handleInboundForwardedChannel` (lokala TCP-
    anslutningen istället för SSH-kanalen) — kraschade direkt så fort riktig
    data flödade igenom. (2) `sendTCPForwardingRequest` är dokumenterat
    "inte trådsäker, får bara anropas på kanalens egen event loop", men en
    `async`-fortsättning garanterar inte det — måste skickas in explicit via
    `channel.eventLoop.execute { ... }` i både `openRemotePortForward` och
    `close()`. (3) Testserverns `stopListening()` kraschade med NIOs egen
    "BUG DETECTED"-skydd mot att anropa `.wait()` på en event loop-tråd.
  - **CLI-koppling för `-R`** (2026-07-06): ✅ klart i `bastion-cli`, symmetriskt
    med `-L` (samma `[bindHost:]bindPort:targetHost:targetPort`-syntax,
    samma `LocalForwardSpec`-parser återanvänd rakt av). `bastion-cli -R ...`
    öppnar fjärrtunneln, väntar på Ctrl+C, stänger rent.
  - **Dynamisk (`-D`, SOCKS5)** (2026-07-06): ✅ klart, `SOCKSProxy.swift`.
    En egen SOCKS5-handskakningshandler (RFC 1928, ackumulerar fragmenterade
    TCP-bytes tills ett helt ramverk kan avkodas) — stödjer IPv4/domännamn/
    IPv6 som måladress, ingen auth (bara `NO AUTHENTICATION REQUIRED`, lokal
    trådad tunnel). Målet klienten begär (godtyckligt, PER anslutning — det
    är hela poängen med "dynamisk" jämfört med `-L`s fasta mål) öppnas som
    en egen `direct-tcpip`-SSH-kanal, precis som `-L`. CLI: `bastion-cli -D
    [bindHost:]bindPort <host>`.
    **En riktig bugg hittad under end-to-end-verifieringen** (skulle inte
    synts utan ett genuint test — en handrullad SOCKS5-klient som begärde
    TVÅ olika mål i tur och ordning och verifierade att servern faktiskt
    fick rätt targetHost/targetPort för VARDERA, inte bara att data ekade):
    `pipeline.removeHandler(name:)` tar inte effekt omedelbart bara för att
    den anropas — data som klienten (korrekt, efter att ha läst CONNECT-
    svaret) skickade omedelbart därefter hann träffa den gamla handskaknings-
    handlern INNAN borttagningen faktiskt slagit igenom, och sväljdes tyst.
    Fix: handskakningshandlern vidarebefordrar (`context.fireChannelRead`)
    istället för att droppa allt som kommer in efter att den en gång blivit
    klar — oavsett om den formellt redan borttagen ur pipelinen eller inte.
  - **Kvar**: ingen GUI-yta (App/LinuxApp) för `-L`/`-R`/`-D` än — bara
    `bastion-cli` kan starta/stoppa en tunnel hittills.
- **Face ID/Touch ID-app-lås** — ✅ klart i App/. `AppLockManager` (LocalAuthentication,
  `.deviceOwnerAuthentication` — Face ID/Touch ID/lösenkod-fallback), låser vid
  bakgrund (`scenePhase`), egen inställningsyta (menyn i värdlistan, av som
  standard). `NSFaceIDUsageDescription` tillagd i Info.plist (krävs av iOS,
  annars kraschar appen vid första anropet). LinuxApp/Windows: ingen
  motsvarighet — plattformsspecifikt Apple-API.
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
- **Flera samtidiga sessioner** — ✅ klart i App/ (iOS/macOS). `SessionManager`
  (`App/SessionManager.swift`) håller alla öppna sessioner; `MultiSessionView`
  presenterar dem som `TabView`-flikar — SwiftUI river inte ner overksamma
  flikars vyer vid växling, så en bakgrundad session förblir faktiskt
  ansluten utan egen livscykelkod. "Klar" (i `HostDetailView`) döljer bara
  flikväxlaren (`dismiss()`, sessionerna lever kvar); en ny meny-post
  "Stäng session" kopplar faktiskt från. Sista fliken stängd → tillbaka
  till värdlistan automatiskt. **Kvar**: äkta sida-vid-sida Split View
  (iPad/Mac) — bara flikväxling hittills, ingen samtidig visning av två
  terminaler. LinuxApp oförändrad (dess `NavigationSplitView` byter fortfarande
  ut hela detaljvyn vid nytt värdval — samma begränsning som App/ hade innan
  den här ändringen, inte adresserad än).

### Fas C — Differentiatorer bortom Termius
- Docker-hantering ✅ redan klart (App + LinuxApp).
- Systemstatus/dashboard ✅ redan klart.
- **Tailscale-stöd** (nytt, från konkurrentanalysen) — inte påbörjat.
- **WireGuard-profiler** (nytt) — inte påbörjat.
- **tvOS** (nytt, 2026-07-06) — inte påbörjat. Nytt target i `project.yml`,
  samma SwiftUI-kod som iOS/macOS. Scopas som dashboard-/Docker-vy, inte
  en fullt interaktiv terminal (fjärrkontroll-tangentbord är ohanterbart
  för riktig SSH-inmatning). Se VISION.md "Plattformar (tillägg)" för
  resonemanget bakom att tvOS men inte Android/övriga smart-TV-plattformar
  prioriteras nu.
- **Command Library** — ✅ klart, både App/ och LinuxApp. `CommandLibrary`/
  `CommandLibraryEntry` i SSHCore — statisk referensdata (ingen egen lagring,
  till skillnad från `Snippet`), 27 kommandon över alla sju kategorier
  (Docker/Linux/Git/Cloudflare/Tailscale/WireGuard/systemd), var och en med
  beskrivning + valfritt exempel/dokumentationslänk. Kör ett kommando
  återanvänder Snippets variabelifyllning (`CommandLibraryEntry.asSnippet`).

### Fas D — De stora bitarna (ingen ändring i prioritet)
- **SFTP-filhanterare** — ✅ grundfunktionerna klara, både App/ och
  LinuxApp (`SFTPBrowserView`/`SFTPBrowserModel`): bläddra, navigera
  in/upp, ny mapp, döp om, ta bort. Mapp/fil skiljs via
  `SFTPFileAttributes.isDirectory` (läser POSIX-filtypsbitarna
  S_IFDIR/S_IFREG ur `permissions`-fältet — la till det efter att ha
  insett att den ursprungliga testservern bara satte behörighetsbitarna,
  inte typen, vilket hade gjort mapp/fil-särskiljning opålitlig).
  `SFTPProtocol.swift`: SFTP version 3-trådformatet (SSH_FXP_*), rent
  kodat/avkodat. `SFTPClient.swift`: öppnar en "sftp"-subsystem-kanal på
  en `SSHSession` (samma `DirectTCPIPWrapperHandler`-mönster som
  portvidarebefordran återanvänds för ByteBuffer<->SSHChannelData),
  INIT/VERSION-handskakning, id-baserad pending-request-tabell (en
  Swift-aktör — flera samtidiga förfrågningar över samma kanal är säkert).
  API: `realpath`/`stat`/`listDirectory`/`mkdir`/`rmdir`/`remove`/`rename`/
  `readFile`/`writeFile` (chunkad läsning/skrivning) + lägre nivå
  `openFile`/`read`/`write`/`closeFile`.
  30 tester totalt (20 rena protokoll-round-trip + 10 end-to-end mot en
  testserver backad av ett riktigt temp-directory — `FileManager`/
  `FileHandle`, inte bara protokolleko), inklusive ett samtidighetstest
  (10 parallella läsningar, verifierar att id-matchningen inte blandar
  ihop svar). **Ej gjort**: verifiering mot det RIKTIGA `sftp-server`-
  binärprogrammet (`/usr/lib/openssh/sftp-server` finns på den här
  maskinen) — testservern är min egen Swift-implementation av protokollet,
  inte OpenSSHs C-kod; att brygga ett riktigt underprocess-`sftp-server`
  via NIOPipeBootstrap + Foundation.Process är fragilt (dubbel fd-ägande
  mellan Foundation.Pipe och NIO) och sparat som ett eget, separat steg
  om djupare protokollkompatibilitet någonsin behöver verifieras.
  **Kvar**: Drag & Drop, Zip/Tar, chmod/chown, förhandsvisning,
  textredigering.
  **Kvar**: UI (Drag & Drop, Zip/Tar, chmod/chown, förhandsvisning,
  textredigering) i App/ och LinuxApp.
- Inbyggd editor med syntax highlighting
- Plugin-system (Proxmox, TrueNAS, Unraid, Cloudflare, GitHub, Kubernetes)
- ProxyJump, Agent Forwarding, PKCS11, YubiKey, Passkeys
- **OpenSSH-certifikatautentisering** (nytt, 2026-07-05) — stöd för
  `ssh-keygen`-signerade/externt utfärdade SSH-certifikat som en egen
  `HostAuth`-variant, inte bara rå nyckel. De stora molnleverantörerna har
  konvergerat mot exakt den här modellen (identitetsleverantör utfärdar
  ett kortlivat cert efter inloggning, istället för statisk nyckel):
  Cloudflare Access (kortlivade SSH-cert via en app-specifik eller
  konto-CA — kräver `TrustedUserCAKeys` på målservern), Google Cloud
  (OS Login med certifikatbaserad autentisering, `gcloud compute ssh`),
  Microsoft Entra ID (SSH-certifikatautentisering efter inloggning) och
  AWS EC2 Instance Connect (kortlivad — ~60 s — nyckel push till
  instansmetadata; inte riktigt samma CA-cert-mekanism men samma
  grundidé om engångs-/kortlivad autentisering istället för en
  permanent nyckel). Ett generellt OpenSSH-certifikatstöd i SSHCore
  fångar alla fyra utan plattformsspecifik kod.
- Secure Enclave-bunden nyckellagring (i dag: vanlig Keychain)
- **256-färg + True Color i Linux-terminalen** — ✅ klart. `TerminalBuffer.applySGR`
  hanterade tidigare bara 16-färgspaletten (`SGR 30-37/40-47/90-97/100-107`).
  `SGR 38;5;n`/`48;5;n` (256-färgspaletten: 0-15 standard/ljusa, 16-231 en
  6×6×6-RGB-kub, 232-255 en gråskale-ramp) och `38;2;r;g;b`/`48;2;r;g;b`
  (True Color) tillagt. Krävde att `applySGR` skrevs om från en enkel
  `for`-loop till indexbaserad iteration, eftersom dessa koder konsumerar
  flera efterföljande parametrar atomiskt. Ingen dedikerad testfil finns
  för `TerminalBuffer` (upptäckt under arbetet — en tidigare sammanfattning
  påstod felaktigt 17 testfall; verifierat inte sant), så färgmatematiken
  verifierades manuellt (xterm-referensvärden: 196=röd, 46=grön, 21=blå,
  232/255=gråskale-ändpunkter) + byggd/körd (Xvfb) utan krasch. **Kvar**:
  Ligatures, musstöd. Terminalfärger i App/ (SwiftTerm) är opåverkade —
  SwiftTerm har redan eget stöd för det här.
