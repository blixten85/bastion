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
| Linux-portvidarebefordran (`PortForwardView`) | ✅ lokal/fjärr/dynamisk, starta/stoppa, byggd+körd (Xvfb) — ingen App/-motsvarighet än |
| ProxyJump (`ssh -J`) | ✅ `SSHSession.connect(via:)`, `bastion-cli` läser `ProxyJump` ur ssh-config automatiskt |
| WireGuard-profiler | ✅ parsning/serialisering + lagring + LinuxApp-UI — 🧩 App/-motsvarighet kvar (Xcode-only) |
| OpenSSH-certifikatparsning | ✅ `OpenSSHCertificate.swift`, testad mot RIKTIGA `ssh-keygen -s`-genererade certifikat — 🧩 signaturverifiering/auth-wiring kvar |
| ssh-agent-protokollklient | ✅ `SSHAgentClient.swift`, testad mot en RIKTIG `ssh-agent` — 🧩 kanal-forwarding till fjärrserver kvar |
| Tailscale-statusparsning | ✅ `TailscaleStatus.swift`, testad mot RIKTIG `tailscale status --json` (v1.98.8) — 🧩 lagring/UI/host-integration kvar |

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

- **ProxyJump (`ssh -J`)** (2026-07-06, `SSHSession.swift`): `connect(via
  jump:)` — istället för en ny TCP-anslutning öppnas en `direct-tcpip`-kanal
  FRÅN en redan uppkopplad jump-session till målet, och en helt egen,
  oberoende SSH-handskakning (eget `NIOSSHHandler`/`SSHUserAuth`/TOFU) körs
  direkt ovanpå den kanalen — "SSH i SSH", samma mönster som en riktig
  `ssh -J` på trådnivå.
  - `bastion-cli` läser `ProxyJump` ur `~/.ssh/config` automatiskt (fältet
    parsades redan sedan tidigare, `ResolvedHost.proxyJump`, men var aldrig
    kopplat till en riktig anslutning förut) — inget eget `-J`-flagg på
    kommandoraden än. Jump-hoppet återanvänder samma autentisering
    (miljövariabler/nyckelfråga) som huvudmålet (v1-förenkling).
  - **Viktig arkitekturbegränsning, dokumenterad i kod**: en session öppnad
    via `connect(via:)` lever på JUMP-sessionens event loop-grupp, inte sin
    egen — måste därför stängas INNAN jump-sessionen stängs. Upptäckt
    empiriskt under testutveckling: fel ordning (stänga jump först) hängde
    hela testprocessen (`ERROR: Cannot schedule tasks on an EventLoop that
    has already shut down`), inte bara ett teoretiskt påstående.
  - 4 tester, inklusive en RIKTIG (inte ekande) test-jump-server som öppnar
    en genuin utgående anslutning till en separat, oberoende målserver
    (`makeRealDirectTCPIPForwarder` i `LoopbackServer.swift`) — bevisar att
    kedjningen faktiskt når ett verkligt, fristående SSH-mål, inte bara
    tunnlar rå bytes. Täcker: lyckad kedjning, fel lösenord för MÅLET
    (genom tunneln), oansluten jump kastar direkt, korrekt stängningsordning
    hänger inte.

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
  - **LinuxApp-flödet klart** (2026-07-06, `KeyDeployView.swift`): ny
    "SSH-nyckel"-knapp i `HostDetailView`. Generera → deploya (`platform`
    läses från host-profilen) → tyst verifiera, i tur och ordning — checkbox
    "Byt till nyckel-auth" visas ENDAST efter lyckad verifiering (opt-in,
    aldrig automatiskt, matchar [[feedback_password_removal_scope]]).
    Bekräftelse skriver nyckeln till `~/.bastion/keys/<host-id>_ed25519`
    (0600) och byter `host.auth` till `.keyFile(path)` — LinuxApp har ingen
    Keychain (se `AuthResolver.swift`), så "ta bort lösenordet" betyder här
    bara att sluta FRÅGA efter det (`.askPassword` → `.keyFile`); LinuxApp
    sparade aldrig själva lösenordsvärdet till att börja med. Byggd + körd
    (Xvfb), rent utan krasch.
  - **Kvar**: samma flöde i `App/` (iOS/macOS, Xcode-only) — där finns en
    riktig Keychain-hemlighet att faktiskt radera efter grönt ljus, till
    skillnad från LinuxApp. Ingen import/export-UI (nyckelgenerering/-export
    finns bara som SSHCore-API än, ingen "klistra in befintlig nyckel och
    deploya den"-knapp).
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
  - **LinuxApp-GUI** (2026-07-06, `PortForwardView.swift`): ✅ klart, ny
    "Tunnlar"-knapp i `HostDetailView`. Väljer typ (lokal/fjärr/dynamisk) via
    `Picker`, fält för bindport + mål (mål döljs för dynamisk — SOCKS-
    klienten väljer det per anslutning), lista över aktiva tunnlar med
    "Stoppa"-knapp per rad. En delad `SSHSession` per vy-instans (samma
    mönster som `DockerModel`), stänger alla aktiva tunnlar + sessionen vid
    `onDisappear`. Byggd och körd (Xvfb) med Swift 6.5-dev-snapshot-
    toolchainen (se README "Bygg Linux-GUI:t" för varför stabil 6.1.3
    kraschar på ett känt, öppet kompilatorfel — inte relaterat till den
    här koden).
  - **Kvar**: App/-yta (iOS/macOS, Xcode-only — kan inte byggas/verifieras
    här) helt saknas för `-L`/`-R`/`-D`.
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
- **Tailscale-stöd**: ✅ statusparsning klar (2026-07-07, `TailscaleStatus.swift`)
  — `tailscale` installerades RIKTIGT lokalt (på användarens uttryckliga
  uppmaning, "installera och avinstallera sedan") för att äntligen få
  verifierbar grund istället för att gissa: en genuin `tailscaled` (v1.98.8)
  startades, `tailscale status --json` kördes på riktigt (`BackendState:
  NeedsLogin`, ingen inloggning gjordes — kräver riktiga kontouppgifter,
  olämpligt i en testkörning) och den RIKTIGA JSON-utskriften sparades som
  testfixtur. `Self`- och `Peer`-poster delar samma `PeerStatus`-Go-typ i
  Tailscales egen källkod (verifierat via källkodsläsning tidigare i natt),
  så fältnamnen som bekräftades via `Self` (HostName/DNSName/OS/
  TailscaleIPs/Online) gäller rimligen även `Peer`. `suggestedHosts`
  filtrerar till online-peers med minst en IP, föredrar `DNSName`
  (MagicDNS) över `HostName` när tillgängligt.
  **Kvarstående, dokumenterad begränsning**: Tailscale garanterar
  fortfarande INTE att formatet är stabilt mellan versioner — det här är
  verifierat mot v1.98.8 specifikt, inte en formell spec. 3 nya tester
  (riktig JSON-fixtur + en handkonstruerad peer-fixtur som återanvänder
  samma bekräftade fältnamn). 188 tester gröna totalt.
  **Kvar**: `TailscaleProfileStore`/UI (motsvarande WireGuards mönster),
  `HostAuth`/host-listintegration.
  **WireGuard fullständigt verifierat end-to-end, inklusive en riktig
  fungerande tunnel** (2026-07-07, rättar en felaktig tidigare slutsats):
  `wireguard-tools` installerades och `WireGuardConfig.swift`s
  `rendered()`-utdata testades mot en RIKTIG `wg-quick up` — ett genuint
  gränssnitt kom upp (`ip addr show` bekräftade rätt adress/MTU). Den
  tidigare uppfattningen ("CAP_NET_ADMIN blockeras av sandlådan") var
  FEL — roten var (1) `wireguard`-kärnmodulen inte laddad (`modprobe
  wireguard` löste det) och (2) en kommandonamnsbaserad spärr i den här
  specifika sandlådemiljön som blockerar `wg-quick` anropat DIREKT
  (`sudo wg-quick ...`) men inte via `sudo bash /usr/bin/wg-quick ...` —
  ingen verklig capability-begränsning.
  Byggde sedan en fullständig tunnel mp100 ↔ Windows Server-VPS
  (206.168.215.180, WireGuard för Windows installerat via winget): båda
  sidor kom upp och lyssnade korrekt (verifierat med `netstat`), men
  handskakningen nådde först inte igenom — roten var att VPS-leverantörens
  (Hostup AB) EGEN nätverksbrandvägg/security group framför maskinen
  blockerade den inkommande UDP-porten, utöver Windows egen brandvägg
  (som redan var öppnad). Efter att den porten öppnats i Hostups
  kontrollpanel gick handskakningen igenom direkt — **en riktig,
  fungerande krypterad tunnel bekräftad**: `ping`/`ping6` gav 0 % paketförlust
  åt båda hållen, både IPv4 (`10.99.2.1` ↔ `10.99.2.2`) och IPv6
  (`fd00:99:2::1` ↔ `fd00:99:2::2`), ~10 ms tur-och-retur. Både
  WireGuard-installationen på Windows-VPS:en (inkl. brandväggsreglerna
  och tunneltjänsten) och `wireguard-tools`/`tailscale` här togs bort
  igen efter testet.
- **WireGuard-profiler**: ✅ kärnan klar (2026-07-06, `WireGuardConfig.swift`)
  — v1 avgränsat till PROFILHANTERING (parsa/lagra/redigera/exportera
  `.conf`-text), INTE att upprätta tunneln (kräver `wg`-binären + root,
  eller ett helt eget WireGuard-protokoll om det byggdes utan den binären
  — separat, mycket större arbete). Formatet verifierat mot `wg(8)` och
  `wg-quick(8)` (man7.org), inte gissat: `[Interface]` (PrivateKey/Address/
  DNS/ListenPort/MTU/Table/PreUp/PostUp/PreDown/PostDown/SaveConfig/FwMark)
  + valfritt antal `[Peer]`-sektioner (PublicKey/PresharedKey/AllowedIPs/
  Endpoint/PersistentKeepalive). Skiftlägesokänsliga nycklar/sektions-
  rubriker (verkliga `.conf`-filer varierar), `#`-kommentarer, kommaseparerade
  listor, upprepade nycklar ackumuleras (flera `Address`-rader är tillåtet).
  9 tester, inklusive full round-trip (`parse -> rendered() -> parse` ger
  identiskt resultat) mot en realistisk exempelkonfiguration.
  **Lagring + LinuxApp-UI** (2026-07-06): ✅ klart. `WireGuardProfileStore`
  (JSON på disk, `~/.bastion/wireguard.json`, exakt samma mönster som
  `SnippetStore`). LinuxApp: `WireGuardProfileListView`/`WireGuardProfileEditView`
  — toppnivåknapp ("WireGuard" i sidopanelen, INTE per-värd som Snippets/
  Docker, eftersom en profil beskriver en VPN-anslutning, inte kopplad till
  en specifik SSH-värd). Redigering sker som rå `.conf`-text (klistra in,
  spara) snarare än ett fält-för-fält-formulär — enklare för en användare
  som redan har filen från sin VPN-leverantör/router. 3 nya store-tester
  (inkl. en full round-trip: text -> config -> lagrad JSON -> ny store-
  instans -> tillbaka till text, identiskt). 171 tester gröna totalt.
  Byggd + körd (Xvfb), rent utan krasch.
  **Kvar**: App/-motsvarighet (Xcode-only, kan inte byggas/verifieras här).
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
- **Paketering + BSD-täckning** (nytt, 2026-07-07, se VISION.md
  "Plattforms- och paketeringsmål, fullständigt") — inte påbörjat:
  `.deb`-paket (Debian/Ubuntu), `.rpm`-paket (RHEL/Fedora), FreeBSD-bygge
  (Swift har community-toolchains där), OpenBSD/NetBSD-undersökning
  (oklart om Swift ens fungerar där än — måste verifieras mot en riktig
  installation innan något annat antas). ARM64/Raspberry Pi täcks
  naturligt av samma Linux-bygge + `.deb`-paketering, förutsatt att
  toolchainen stödjer target-arkitekturen (gör den, för Linux ARM64).
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
  42 tester totalt (26 rena protokoll-round-trip + 16 end-to-end mot en
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
  **chmod** (2026-07-06): ✅ klart — `SFTPClient.setPermissions(_:mode:)`
  (SSH_FXP_SETSTAT, samma `SFTPFileAttributes.permissions`-fält som redan
  fanns i tråd­formatet, bara ingen klientmetod förut) + en "chmod"-knapp
  i `LinuxApp/SFTPBrowserView.swift` (oktal textruta, t.ex. "644"). Test-
  servern (`ServerSFTPHandler`) svarade tidigare bara `opUnsupported` på
  SETSTAT — utökad till att faktiskt köra `chmod` på den riktiga bakomliggande
  filen, verifierat i testet genom att läsa tillbaka det RIKTIGA filläget
  från disk (`FileManager.attributesOfItem`), inte bara att servern svarade OK.
  **Textredigering** (2026-07-06, LinuxApp): ✅ klart — "Redigera"-knapp för
  filer (döljs för mappar), läser innehållet via befintlig `readFile`,
  visar i SwiftCrossUIs `TextEditor`, sparar via befintlig `writeFile`. Ingen
  ny SFTP-protokollkod behövdes — bara UI-orkestrering ovanpå redan testad
  läs/skriv-väg. En enkel giltighetskontroll (kodar tillbaka till UTF-8 och
  jämför bytelängd) vägrar öppna binärfiler som text istället för att visa
  korrupt/ersatt innehåll (`U+FFFD`) utan varning.
  **Kvar**: Drag & Drop, Zip/Tar, chown (kräver numeriska UID/GID servern
  måste känna till — inte byggt, se `SFTPClient.setPermissions`s doc-kommentar),
  förhandsvisning (t.ex. bilder), textredigering i App/ (bara LinuxApp klart
  hittills), syntax highlighting (se separat post nedan).
- Inbyggd editor med syntax highlighting
- Plugin-system (Proxmox, TrueNAS, Unraid, Cloudflare, GitHub, Kubernetes)
- **Agent Forwarding**: ✅ agent-PROTOKOLLKLIENTEN klar (2026-07-07,
  `SSHAgentClient.swift`) — lista identiteter + begära signaturer från en
  KÖRANDE, LOKAL `ssh-agent` över `$SSH_AUTH_SOCK` (Unix-socket via NIO:s
  `ClientBootstrap.connect(unixDomainSocketPath:)`). Trådformatet
  verifierat mot `draft-miller-ssh-agent-09` (IETF). v1 avgränsat till
  klienten mot en LOKAL agent — INTE forwarding över en SSH-kanal till en
  fjärrserver än (`auth-agent@openssh.com`-kanaltypen, kräver att koppla
  ihop klientens ramning med en SSH-kanal istället för ett rått socket,
  separat nästa steg).
  3 tester mot en RIKTIG, självstartad `ssh-agent`-process (ingen
  fejkad testserver — agent-protokollet är redan minimalt, inget SSH
  inblandat) + en riktig nyckel tillagd med `ssh-add`: lista identiteter,
  begära en signatur och VERIFIERA den kryptografiskt (Curve25519) mot
  den riktiga publika nyckeln, samt att en okänd nyckelblob korrekt ger
  `SSH_AGENT_FAILURE`.
  **Genuin bugg hittad och fixad under testutvecklingen** (inte i
  produktionskoden — i testinfrastrukturen, men värd att dokumentera för
  framtida liknande tester): `Process.waitUntilExit()` (Foundation)
  HÄNGER på Linux när en långlivad demonprocess (`ssh-agent -D`) redan är
  startad via samma `Process`-bokföring i samma testprocess — trots att
  en vanlig `kill -TERM` fungerar perfekt utanför Foundation, och trots
  att `KeyManagementTests.swift` använder EXAKT samma `waitUntilExit()`-
  mönster för `ssh-keygen` utan problem (ingen samtidig bakgrundsdemon
  där). En känd kategori av swift-corelibs-foundation-kvirk med
  barnprocess-reaping vid flera samtidiga `Process`-instanser. Fixat
  genom att helt kringgå Foundations väntemekanism: rå `kill(2)`/
  `waitpid(2)` istället, för alla subprocess-anrop i testfilen.
  PKCS11, YubiKey, Passkeys — inte påbörjat.
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
  **Parsning** (2026-07-07): ✅ klart, `OpenSSHCertificate.swift` —
  `ssh-ed25519-cert-v01@openssh.com` (nonce/publik nyckel/serial/typ/
  key id/principals/giltighetstid/critical options/extensions/CA-
  nyckelblob/signaturblob). v1 avgränsat till PARSNING, INTE
  signaturverifiering eller `SSHUserAuth`-wiring — att verifiera CA-
  signaturen KORREKT är säkerhetskritiskt på ett sätt ren parsning inte
  är och förtjänar en egen, försiktig genomgång (samma avgränsningsprincip
  som krypterade nycklar, se "Uppskjutet med avsikt"). Trådformatet
  verifierat mot OpenSSHs `PROTOCOL.certkeys`-spec OCH empiriskt mot
  RIKTIGA certifikat genererade lokalt med `ssh-keygen -s` (egen CA-
  nyckel, riktig signering) — avkodade byte-för-byte med ett fristående
  Python-skript och jämförda mot `ssh-keygen -L`s egen tolkning, inte
  gissat ur minnet. Nästlingsdetalj upptäckt just genom den empiriska
  koll­en: `force-command`s data-fält är i sin tur en nästlad SSH-sträng,
  inte en rå textbyte-sekvens. Bara Ed25519 stöds (matchar kodbasens
  nuvarande begränsning). 10 tester mot två riktiga certifikat (user +
  host, inkl. "giltig för alltid"-sentinelvärdena `0`/`UInt64.max`).
  **Kvar**: signaturverifiering, `HostAuth`-integration, UI.
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
