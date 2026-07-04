# bastion — AI Agent Guide

Fri, öppen, fristående SSH-klient. Kärnan (`Sources/SSHCore`, ren SwiftNIO)
bygger på Linux och Apple. `App/` (iOS/macOS, SwiftUI) är Xcode-only.
`LinuxApp/` (SwiftCrossUI/GTK4) är ett eget SwiftPM-paket.

## Conventions

- Ny funktionalitet i kärnan (`SSHCore`) ska ha tester i `Tests/SSHCoreTests`
- `App/` byggs bara i Xcode — kan inte verifieras via `swift build` på Linux
- `LinuxApp/` ligger medvetet i ett eget paket (se `LinuxApp/Package.swift`)
  för att inte dra in SwiftCrossUI-beroenden i rotens `swift build`/`swift test`
- OAuth är PKCE-baserat (`Sources/SSHCore/OAuthPKCE.swift`) — inga klienthemligheter i koden
- Hemligheter (nycklar, lösenfraser, tokens) lämnar aldrig enheten okrypterade

## Allowed
- Create branches
- Modify code
- Run tests
- Open PRs

## Forbidden
- Push directly to main/master
- Merge PRs
- Delete branches
- Disable workflows
- Modify secrets
- Change GitHub org settings

## Requirements
- All tests must pass (`swift test` i repo-roten)
- Keep PRs focused
- Never include unrelated changes
- Never commit credentials
- Never force push
