# Vision

> Den snabbaste, snyggaste och mest integritetsvänliga SSH-klienten för iPhone, iPad, macOS, Windows och Linux. Alla kärnfunktioner är gratis. Ingen reklam. Ingen obligatorisk inloggning. Ingen prenumeration.

Ett flerårigt projekt, inte "en app" — en plattform.

Affärsmodellen:

* 100 % öppen källkod (MIT).
* Donationer via GitHub Sponsors och liknande.
* Inga funktionslås.
* Eventuella betalda intäkter kan komma från frivilliga tjänster, exempelvis en molntjänst för synk, men appen ska fungera fullt ut utan den.

---

## Målgrupp

* Systemadministratörer
* DevOps
* Docker-användare
* Linux-entusiaster
* Homelab
* Raspberry Pi
* VPS-användare
* Molnadministratörer
* Nätverkstekniker
* Programmerare

---

## Arkitektur

```
Core

SSH
SFTP
Terminal
Host Database
Sync Engine
Plugin API
UI Components
Cloud Providers
```

Samma kärna används på flera plattformar — bara UI-lagret är plattformsspecifikt.

---

## Plattformar

Fas 1: iPhone, iPad
Fas 2: macOS
Fas 3: Linux
Fas 4: Windows

Android kan vänta om resurserna är begränsade.

---

## Kärnfunktioner

### SSH

* SSH
* SSH Config
* ProxyJump
* Agent Forwarding
* SSH Keys
* PKCS11
* YubiKey
* Passkeys där protokollet tillåter
* Ed25519, ECDSA, RSA

### Terminal

* Flera flikar, Split View, flera sessioner
* Färgteman, True Color, Ligatures (valfritt)
* Musstöd där plattformen stöder det
* UTF-8, Emoji, Unicode

### iPhone-tangentbord

Här kan konkurrenter överträffas:

* Ctrl, Esc, Tab, Pilar, Alt, F1–F12
* Snabbkommandon, programmerbara knappar

### Hosts

Mycket bättre än Termius.

```
Produktion
    Web / API / Database
Homelab
    Plex / NAS / Docker
Kunder
Projekt
Favoriter
```

Taggar istället för enbart mappar.

### Dashboard

När man trycker på en server visas direkt (allt via SSH, ingen agent krävs):

CPU, RAM, Disk, Docker, Temperatur, Uptime, Kernel, OS, IP-adresser, SSH-nycklar, Aktiva användare.

### Docker

Här kan projektet sticka ut — ingen annan mobilklient gör det här riktigt bra:

```
Containers / Images / Volumes / Networks / Compose / Logs / Restart / Update / Shell
```

### SFTP

Full filhanterare: Drag & Drop, Zip, Tar, Extract, Permissions, Chmod, Chown, symboliska länkar, förhandsvisning, textredigering.

### Editor

Inbyggd editor med syntax highlighting: YAML, JSON, Docker Compose, Bash, Python, Go, Rust, JavaScript, Markdown.

### Snippets

Inte bara text — kan ha variabler. Exempel:

```
Restart Plex → ssh → docker compose restart plex
```

### Command Library

Docker, Linux, Git, Cloudflare, Tailscale, WireGuard, systemd — varje kommando med beskrivning, exempel, dokumentation.

### Plugin-system

Projektets stora potentiella styrka. Alla plugins separata paket:

Docker, Proxmox, TrueNAS, Unraid, Cloudflare, GitHub, Kubernetes.

### Synk

Ingen inloggning krävs. Alternativ: iCloud, Git, GitHub, WebDAV, Dropbox, OneDrive, Syncthing, självhostad server.

### Säkerhet

* Allt krypteras lokalt. Nycklar lämnar aldrig enheten okrypterade.
* Face ID/Touch ID. Hardware-backed Secure Enclave där möjligt.
* Full offline-funktion.

### Design

Inte kopiera Termius. Inspireras av Apples Human Interface Guidelines, minimalism, snabbhet, mörkt läge, flytande animationer, stor fokus på läsbarhet.

---

## Namn

Några idéer: Forge, Relay, Bastion, North, Atlas, Harbor, Haven, Ember, Helix, Terminal One, OpenSSH Studio, Dock.

Kontrollera alltid varumärken innan ni bestämmer er.

(Valt arbetsnamn: **Bastion**.)

---

## Teknik

* **iOS/macOS:** Swift + SwiftUI
* **SSH:** OpenSSH eller ett välunderhållet bibliotek med kompatibel licens
* **Terminalemulering:** en etablerad VT100/xterm-kompatibel motor
* **Databas:** SQLite
* **Kryptering:** plattformarnas säkra nyckelhantering (Keychain/Secure Enclave på Apple-enheter)
* **Synk:** iCloud och Git som första alternativ

---

## Utvecklingsplan

**Version 0.1**

* SSH
* Nyckelhantering
* Hostlista
* Terminal
* SFTP

**Version 0.5**

* Taggar
* Dashboard
* Snippets
* Face ID
* Import från `~/.ssh/config`

**Version 1.0**

* Docker-stöd
* Editor
* Synk
* Flera sessioner
* Split View

**Version 2.0**

* Plugin-system
* Proxmox
* Kubernetes
* Tailscale
* WireGuard
* Git-integration

---

## En sak att prioritera högt

Det största misstaget många liknande projekt gör är att försöka lägga till "allt". Principen istället:

> **Allt som en systemadministratör använder varje dag ska kännas snabbare och enklare än i Termius. Allt mer specialiserat ska kunna läggas till via plugins.**

Det håller kärnan lätt, samtidigt som projektet kan växa med bidrag från andra utvecklare utan att bli svårunderhållet.

---

Det här dokumentet ovanför den här linjen är den ursprungliga visionen,
bevarad orört som historisk referens. Faktiska tekniska val (som avviker en
del — se [ROADMAP.md](ROADMAP.md) "Tekniska avsteg från visionen") och
status mot punkterna ovan finns i [ROADMAP.md](ROADMAP.md).

---

## Tillägg efter den ursprungliga visionen (2026-07-04)

Följande identifierades i en uppföljande konkurrentanalys — inte en del av
originalvisionen ovan, men bygger vidare på samma grundtes.

### Konkurrentlandskap

Termius har gradvis låst grundfunktioner (synk, snippets, bättre host-
hantering) bakom ett Pro-abonnemang — precis den frustrationen Bastion
adresserar.

| Klient | Styrka | Svaghet |
|---|---|---|
| Termius | Mycket genomarbetad UX, mogen på alla plattformar | Grundfunktioner bakom Pro-prenumeration |
| Tabby | Fri, öppen källkod, kompetent på desktop | Ingen mobilklient |
| Termix | Aktivt projekt, self-hosting-vänligt | Fokuserar på self-hosting-hantering, inte en förstklassig native iOS-upplevelse |
| Magic Term | Gratis, E2E-krypterad synk, uttalat en Termius-ersättare | Ungt projekt, omoget |
| Conduit | Fri, öppen källkod, native iOS | Ungt, inte lika moget som Termius |

**Bastions nisch:** fri för alltid + native iOS/macOS-först (inte React
Native/Flutter) + samma kärna på alla plattformar. Ingen av konkurrenterna
ovan täcker exakt den kombinationen idag.

**Positionering:** det som gör att folk betalar för Termius är UX (hostlista,
färgkodning, favoriter, snabb sök, split view, biometrisk upplåsning, bra
tangentbord), inte SSH-protokollet i sig. Målet är UX-paritet med Termius,
inte fler protokollfunktioner för sin egen skull.

**Juridiskt:** bygg inte något som visuellt eller varumärkesmässigt kan
uppfattas som en kopia av Termius — se "Design"-avsnittet ovan (redan i
originalvisionen: "Inte kopiera Termius").

### Plattformar (tillägg, 2026-07-06)

- **tvOS** — tillagd i Fas C-backloggen. Billigt att lägga till (samma
  Xcode-projekt, samma SwiftUI-kod, samma Apple-utvecklarkonto som redan
  är på gång) och en riktig differentiator — ingen av konkurrenterna ovan
  har en tvOS-app. Scopas som en dashboard-/Docker-vy, INTE en fullt
  interaktiv terminal — att skriva SSH-kommandon med en Apple TV-fjärrkontroll
  är en usel upplevelse, men systemstatus/containrar på storbild är
  användbart (bygger vidare på Dashboard/Docker-vyerna som redan finns).
- **Android — INTE valfritt, uppdaterat 2026-07-07 (ägarbeslut).**
  Tidigare formulerat som "kan vänta" — omvärderat. Bastions uttalade
  syfte är att ersätta Termius på BRED FRONT, inte bara på Apples
  plattformar: "Alla frågor, förväntningar och krav en utvecklare och
  nybörjare kan ha ska finnas där. Det ska inte finnas luckor som
  skaver." Termius har en mogen Android-app, och sysadmins/DevOps är
  notoriskt plattformsagnostiska — att sakna Android är exakt den sortens
  lucka. Alltså: Android är en del av slutmålet, inte en valfri
  utökning, även om den kommer SEKVENSERAD EFTER de plattformar som
  redan är i gång (iOS/macOS/Linux/Windows) — inte "om resurserna
  räcker", utan "när tur kommer".
  Teknisk verklighet oförändrad och värd att ha i åtanke: `SSHCore` är
  ren Swift utan Android-motsvarighet, så det här är den enda
  plattformen i backloggen som INTE bara är ett nytt Xcode-target eller
  SwiftPM-paket som återanvänder samma kod. Två realistiska vägar när
  det blir aktuellt:
  - **Skip** (skip.tools) — transpilerar SwiftUI → Kotlin/Compose,
    skulle i teorin kunna återanvända mycket av `App/`s vylager rakt
    av. Växande men fortfarande ett yngre verktyg — kräver en egen
    utvärdering av hur moget det är för en app av den här komplexiteten
    (terminalrendering, PTY, nätverkskod) den dagen det blir aktuellt,
    inte antaget i förväg.
  - **Separat Kotlin-app** — mer beprövad väg, men innebär i praktiken
    en HELT EGEN SSH-implementation i Kotlin/Java (eller ett JVM-
    kompatibelt SSH-bibliotek som t.ex. Apache MINA SSHD/JSch) parallellt
    med `SSHCore` — dubbel underhållsbörda för varje ny SSH-funktion
    (cert-auth, agent-protokoll, SFTP, portvidarebefordran m.m. måste
    byggas/underhållas två gånger, en gång per språk/plattform).
- **Övriga smart-TV-plattformar** (Tizen/webOS/Roku m.fl.) — medvetet
  bortvalda. Egna, icke-Swift-ekosystem utan någon kodåteranvändning alls
  — en separat omskrivning per plattform, för stort scope för ett
  soloprojekt.

### Nya funktionsidéer (inte i originalvisionen)

- **Port Forwarding** (lokal `-L`, fjärr `-R`, dynamisk `-D`) — en av
  Termius huvudfunktioner, saknas explicit i SSH-listan ovan (som bara
  nämner ProxyJump/Agent Forwarding).
- **Tailscale-stöd** — koppla mot Tailscale-nätverk för värdar.
- **WireGuard-profiler** — hantera WireGuard-konfigurationer i appen.
- **Telnet-stöd** (tillägg, 2026-07-07, ägarfråga) — INTE påbörjat.
  Enklare protokoll (RFC 854) men HELT SEPARAT från SSH — okrypterat,
  ingen nyckelhantering, egen förhandling (option negotiation). Skulle
  vara en egen `TelnetSession`-motsvarighet till `SSHSession`, inte en
  utökning av den befintliga SSH-kärnan. Legitimt värdefullt för äldre
  nätverksutrustning (switchar/routrar utan SSH) — en del av målgruppen
  (nätverkstekniker) stöter på det.
- **Kör kommando automatiskt vid anslutning** ("startup snippet",
  tillägg, 2026-07-07, ägarfråga) — INTE påbörjat, men lågt hängande
  frukt: `Snippet`/`SnippetStore` finns redan, kräver bara ett nytt
  `Host`-fält (t.ex. `startupCommand: String?`) + att `SSHSession`/
  terminalvyn kör det direkt efter lyckad anslutning, innan interaktiv
  input tas emot. Motsvarande Termius "Startup Snippet".
- **Slutmål (tillägg, 2026-07-07): inget externt beroende.** Bastion ska
  kunna upprätta WireGuard/Tailscale-tunnlar HELT SJÄLV — inte bara peka
  på en `wg`/`tailscale`-installation användaren redan gjort separat.
  "Fristående app" (se första stycket i README) ska gälla nätverkslagret
  också, inte bara SSH-klienten i sig. Se ROADMAP.md "Native WireGuard/
  Tailscale — inget externt beroende" för den tekniska planen (nedladdade
  plattformsbinärer med versionsval på desktop, NetworkExtension på iOS).

Se [ROADMAP.md](ROADMAP.md) för hur dessa är prioriterade in i backloggen.

### Plattforms- och paketeringsmål, fullständigt (tillägg, 2026-07-07)

Slutmålet — uttryckt explicit av användaren — är genuin cross-platform-täckning
med synk mellan ALLA enheter, inte bara Apple-ekosystemet:

- **Apple**: iPhone, MacBook (macOS), Apple TV (tvOS) — redan i Fas 1/2/
  "Plattformar (tillägg, 2026-07-06)" ovan.
- **Windows** — redan Fas 4 i originalvisionen, `WindowsApp/` påbörjat
  (blockerat av uppströms swift-nio-buggar just nu, se ROADMAP).
- **Linux** — redan Fas 3, men paketeringsmålet är BREDARE än "bygger på
  Linux": bygg-från-källkod (redan möjligt), **.deb-paket** (Debian/Ubuntu),
  **.rpm-paket** (RHEL/Fedora). Inget paketeringsarbete gjort ännu — bara
  `swift build`/CI-verifiering finns idag.
- **BSD** (NYTT, inte i någon tidigare version av visionen): FreeBSD,
  OpenBSD, NetBSD. Swift har officiellt stöd för FreeBSD (community-
  underhållna toolchains); OpenBSD/NetBSD-stöd för Swift är betydligt
  omognare/experimentellt — inte verifierat att det ens fungerar, se
  ROADMAP för status när det undersöks.
- **CPU-arkitekturer** (NYTT, explicit): x86/amd64 OCH ARM64 — inklusive
  Raspberry Pi (ARM64 Raspberry Pi OS är en Debian-derivata, så
  .deb-paketering + ARM64-byggen täcker den naturligt, förutsatt att
  Swift-toolchainen stödjer target-arkitekturen, vilket den gör för
  Linux ARM64).

Se [ROADMAP.md](ROADMAP.md) för hur detta prioriteras in i backloggen —
paketeringsarbetet (deb/rpm) och BSD-portning är inte påbörjat än.

### Native filhanterare-integration + molnlagring som filkälla (tillägg, 2026-07-07)

Utöver att Bastion är en egen app: integrera med varje plattforms EGEN
filhanterare, och låta molnlagringstjänster bläddras som allmänna filkällor
(inte bara som synkbackend för host-databasen, vilket redan finns).

- **Apple Filer/Finder** — `FileProvider`-ramverket (`NSFileProviderReplicatedExtension`,
  iOS 11+/macOS 11+), INTE den äldre "Document Provider"-API:n. Beprövad väg
  — **Blink Shell gör redan exakt detta** (bläddra/förhandsgranska/redigera
  fjärrfiler som om de vore lokala, i Filer-appen). Kräver ett separat
  Xcode-extension-target ("File Provider Extension") + delad App Group med
  huvudappen. Fungerar på både iOS och macOS (macOS-stödet är sämre
  dokumenterat men bekräftat fungera i praktiken av andra). STÖDS INTE under
  Mac Catalyst — måste vara en native macOS-extension om Mac ska nås direkt.
  API:t är callback-baserat, inte async/await — viss friktion mot
  Swift-concurrency att vänta. En enkel, strömmande provider (v1) är rimlig;
  en fullt "replicated" provider (offline-cache, konfliktlösning,
  miniatyrer) är betydligt större arbete.
- **Windows Utforskaren** — mest realistiska väg är **WinFsp** (öppen källkod,
  FUSE-motsvarighet för Windows, GPLv3 + FOSS-undantag). **`sshfs-win`
  (underhållet av WinFsp:s egen upphovsman) monterar redan idag en SFTP-värd
  som en nätverksenhet i Utforskaren** — bevisar att hela konceptet fungerar,
  men är en C/Cygwin-wrapper, inte Swift. Rätt väg för Bastion: en egen
  WinFsp-filsystemsprovider (C-API, samma interop-mönster SwiftNIO redan
  använder för Windows-syscalls) backad av Bastions EGEN `SFTPClient` —
  genuint nytt ingenjörsarbete (path-upplösning, handtagscache,
  läs/skriv-callbacks), inte bara en wrapper. Shell Namespace Extensions
  (äldre COM-baserad API) och Cloud Filter API (det OneDrive/Dropbox
  använder, partner-spärrat + designat för "placeholder+synk", inte generell
  bläddring) övervägdes och valdes bort.
- **Molnlagring som filkälla** (inte bara synkbackend) — de OAuth-scope:er
  Bastion redan använder för att synka host-databasen är MEDVETET
  app-mapp-avgränsade och räcker INTE för generell bläddring: Dropbox
  (`files.content.write/read`, App folder-bara — behöver `full_dropbox`),
  Google Drive (`drive.appdata`, en DOLD app-datamapp — helt fel scope,
  behöver `drive`/`drive.readonly` med en tyngre Google-granskningsprocess),
  OneDrive (`Files.ReadWrite.AppFolder` — behöver `Files.ReadWrite.All`).
  Alltså inte en liten utökning: nya scope:er, nya samtyckesskärmar, ny
  klientkod (mappträd-bläddring, godtycklig upp/nedladdning) — separat
  kodväg från den befintliga en-fils-synken.
  **AWS** ("vad de nu har") har inget konsument-OAuth-flöde ("logga in med
  AWS" finns inte för det här användningsfallet) — realistisk modell:
  användaren klistrar in sin egen Access Key ID + Secret (eller
  STS-token) + bucket/region, Bastion signerar förfrågningar själv
  (AWS SigV4 — en väldokumenterad, stabil spec, till skillnad från t.ex.
  Tailscales "subject to change"-JSON). Fullt implementerbart som en egen
  Swift-klient, inget tredjeparts-SDK-beroende krävs.

Ingenting av detta är påbörjat. Se [ROADMAP.md](ROADMAP.md) för prioritering.

### Tillgänglighet — styrning via iOS inbyggda hjälpmedel (tillägg, 2026-07-10)

Bastion ska gå att styra fullt ut med iOS/iPadOS inbyggda tillgänglighetsfunktioner
för användare med syn-, hörsel- eller rörelsenedsättning — inte ett eget
tillgänglighetsläge byggt från grunden, utan att appen är en bra medborgare i
Apples befintliga ramverk (samma princip som native filhanterare-integration ovan:
haka i plattformens egna verktyg snarare än att uppfinna egna).

- **VoiceOver (blind/synskadade)** — kräver korrekta accessibility labels/traits/
  hints på alla UI-element (SwiftUI ger mycket av detta gratis för standardkontroller).
  Den svåra biten är **terminalvyn**: en tät monospace-textgrid renderas normalt
  som en opak Canvas/bitmap, vilket är osynligt för VoiceOver. Måste exponeras som
  radvis/tecken-navigerbara `accessibilityElement`s så innehållet går att läsa upp
  — inte bara knapparna runt terminalen. Ingen etablerad SSH-klient (Termius,
  Blink) är känd för att ha löst detta fullt ut; kräver egen UX-design (radvis
  navigering? ett explicit "läs hela skärmen"-läge?), inte bara en checkbox.
- **Voice Control / Switch Control (rörelsenedsättning)** — röststyrd eller
  switch-baserad navigering/aktivering fungerar oftast automatiskt med standard
  SwiftUI-kontroller (`Button`, `List` osv.); kräver mest disciplin att INTE bygga
  custom-gester utan switch-tillgängligt fallback.
- **Dövhet/hörselnedsättning** — appen är redan textbaserad och ljudoberoende i
  sin natur. Kravet framåt: alla framtida notiser/larm (tappad anslutning,
  långkörande kommando klart, etc.) måste ha visuell + haptisk feedback, aldrig
  enbart en ljudsignal. Visuell + haptisk feedback räcker dock INTE ensamt för
  blinda VoiceOver-användare (dövblindhet, eller synskadad utan hörselnedsättning
  som ändå missar en ren visuell toast) — samma notiser måste även exponera en
  tillgänglig status/announcement (t.ex. `UIAccessibility.post(.announcement)`),
  inte bara synas/kännas.
- **Dynamic Type / kontrast** — terminaltemana (se D-passet i
  iOS-TestFlight-backloggen, 20–25 teman) bör inkludera hög-kontrast-varianter;
  chrome-text (ej terminalcell-grid, som har egen fontstorleksinställning) ska
  följa systemets Dynamic Type.

Inget av detta är påbörjat. Största tekniska osäkerheten är VoiceOver mot
terminalgriden — ett genuint UX-designproblem, inte ett rent implementationsjobb.
