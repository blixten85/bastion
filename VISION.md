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
- **Android** — kvarstår i backloggen som ett stort, separat initiativ
  (inte närmast i tur). SSHCore är ren Swift; en Android-app skulle kräva
  antingen Skip (SwiftUI→Kotlin/Compose-transpilering) eller en helt
  separat Kotlin-app som pratar med kärnan på något sätt — en annan
  kostnadsnivå än tvOS. Termius har redan en Android-app, så det är
  paritet snarare än differentiering (fast "gratis för alltid" håller
  som vinkel även där).
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
