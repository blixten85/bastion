# bastion — Claude Code Guide

Fri, öppen, fristående SSH-klient. Kärnan (`Sources/SSHCore`, ren SwiftNIO)
bygger på Linux och Apple. `App/` (iOS/macOS, SwiftUI) är Xcode-only.
`LinuxApp/` (SwiftCrossUI/GTK4) är ett eget SwiftPM-paket.

## Conventions

- Ny funktionalitet i kärnan (`SSHCore`) ska ha tester i `Tests/SSHCoreTests`
- `App/` byggs bara i Xcode — kan inte verifieras via `swift build` på Linux;
  CI:t (`.github/workflows/xcode.yml`) bygger det på en macOS-runner
- `LinuxApp/` ligger medvetet i ett eget paket för att inte dra in
  SwiftCrossUI-beroenden i rotens `swift build`/`swift test`
- OAuth är PKCE-baserat — inga klienthemligheter i koden, bara publika klient-ID:n
