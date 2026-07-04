# Vision

> Den snabbaste, snyggaste och mest integritetsvänliga SSH-klienten för iPhone, iPad, macOS, Windows och Linux. Alla kärnfunktioner är gratis. Ingen reklam. Ingen obligatorisk inloggning. Ingen prenumeration.

Ett flerårigt projekt, inte "en app" — en plattform.

Affärsmodellen:

* 100 % öppen källkod (MIT).
* Donationer via GitHub Sponsors och liknande.
* Inga funktionslås.
* Eventuella betalda intäkter kan komma från frivilliga tjänster, exempelvis en molntjänst för synk, men appen ska fungera fullt ut utan den.

En sak att prioritera högt: det största misstaget många liknande projekt gör är att försöka lägga till "allt". Principen istället:

> **Allt som en systemadministratör använder varje dag ska kännas snabbare och enklare än i Termius. Allt mer specialiserat ska kunna läggas till via plugins.**

Det håller kärnan lätt, samtidigt som projektet kan växa utan att bli svårunderhållet.

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

Arbetsnamn: **Bastion**. Andra idéer som övervägdes: Forge, Relay, North, Atlas, Harbor, Haven, Ember, Helix, Terminal One, OpenSSH Studio, Dock.

---

## Teknik

* **iOS/macOS:** Swift + SwiftUI
* **SSH:** SwiftNIO SSH (ren Swift, samma kärna på Linux och Apple)
* **Terminalemulering:** SwiftTerm (Apple), egenskriven VT100/ANSI-tolk (Linux, SwiftCrossUI saknar en färdig terminalwidget)
* **Databas:** JSON (host-databas), SQLite inte nödvändigt ännu
* **Kryptering:** Keychain/Secure Enclave på Apple, AES-256-GCM + PBKDF2 för sync
* **Synk:** mapp-baserad (iCloud/Dropbox/Syncthing/Git) + OAuth2/PKCE-kontointegration (Dropbox/Google Drive/OneDrive)
* **Linux-GUI:** SwiftCrossUI (GTK4)

---

## Utvecklingsplan (ursprunglig)

**Version 0.1:** SSH, nyckelhantering, hostlista, terminal, SFTP
**Version 0.5:** Taggar, dashboard, snippets, Face ID, import från `~/.ssh/config`
**Version 1.0:** Docker-stöd, editor, synk, flera sessioner, Split View
**Version 2.0:** Plugin-system, Proxmox, Kubernetes, Tailscale, WireGuard, Git-integration

Se [ROADMAP.md](ROADMAP.md) för faktisk status mot den här visionen.
