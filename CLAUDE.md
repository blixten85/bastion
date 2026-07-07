# bastion — Claude Code Guide

Fri, öppen, fristående SSH-klient. Kärnan (`Sources/SSHCore`, ren SwiftNIO)
bygger på Linux och Apple. `App/` (iOS/macOS, SwiftUI) är Xcode-only.
`LinuxApp/` (SwiftCrossUI/GTK4) är ett eget SwiftPM-paket. `Android/`
(Kotlin/Gradle) är en helt separat portering — `SSHCore` är ren Swift utan
Android-motsvarighet, så Android-sidan bygger på Apache MINA SSHD istället
för att dela kod med de andra plattformarna.

## Conventions

- Ny funktionalitet i kärnan (`SSHCore`) ska ha tester i `Tests/SSHCoreTests`
- `App/` byggs bara i Xcode — kan inte verifieras via `swift build` på Linux;
  CI:t (`.github/workflows/xcode.yml`) bygger det på en macOS-runner
- `LinuxApp/` ligger medvetet i ett eget paket för att inte dra in
  SwiftCrossUI-beroenden i rotens `swift build`/`swift test`
- `Android/` byggs via `./gradlew` (kräver JDK 17+ och Android SDK
  command-line tools, se `Android/local.properties` som inte committas)
- OAuth är PKCE-baserat — inga klienthemligheter i koden, bara publika klient-ID:n
