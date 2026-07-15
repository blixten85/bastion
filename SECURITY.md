# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please **do not** create a public issue. Instead, report it privately.

### How to Report

- **Email:** [dev@denied.se]
- **GitHub:** Use the "Report a vulnerability" button under the Security tab

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Any suggested fixes (optional)

### Response Timeline

| Stage | Timeframe |
|-------|-----------|
| Initial acknowledgment | Within 48 hours |
| Assessment | Within 5 business days |
| Fix implementation | Based on severity |
| Public disclosure | After fix is released |

### Scope

This security policy covers:

- `Sources/SSHCore` (SSH-transport, autentisering, host-databas, sync-kryptering)
- `App/` (iOS/macOS-appen, inklusive OAuth-kontointegration)
- `LinuxApp/` (Linux-GUI:t)
- GitHub Actions-workflows och repo-konfigurationen

### Out of Scope

- Tredjepartsberoenden (SwiftNIO, SwiftNIO SSH, swift-crypto, SwiftCrossUI, SwiftTerm m.fl.) — rapportera till respektive projekt
- Dropbox/Google/Microsofts egna API:er och OAuth-tjänster

## Security Best Practices

### For Contributors

1. **Never commit secrets** – klient-hemligheter, tokens eller lösenfraser
2. **OAuth är PKCE-baserat** – klienten (appen) bär aldrig ett hemligt secret; bara ett publikt klient-ID hör hemma i `App/OAuthProviders.swift`
3. **Nycklar/lösenord lämnar aldrig enheten okrypterade** – se `SSHCore/SyncCrypto.swift` (AES-256-GCM + PBKDF2) och `App/Keychain.swift`
4. **Granska beroenden** – Dependabot håller dem uppdaterade automatiskt

### API-nyckelhantering

Den här appen hanterar SSH-nycklar och OAuth-tokens. De:

- Lagras i systemets Keychain (iOS/macOS) — aldrig i klartext på disk
- Krypteras (AES-256-GCM) innan de lämnar enheten vid synk
- Listas aldrig i `.gitignore`-undantagna filer eller commit-historik

Om du av misstag exponerar en hemlighet (t.ex. i en chatt eller ett issue):

1. Återkalla/regenerera den omedelbart hos leverantören (Dropbox App Console, Google Cloud Console, Azure-portalen)
2. Följ [GitHubs guide för att ta bort känslig data](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)
3. Kontakta maintainern

## Supported Versions

| Version | Supported |
|---------|-----------|
| Senaste commit på `main` | ✅ |
| Äldre commits | ❌ |

## Acknowledgments

We appreciate responsible disclosure. Security researchers who report valid vulnerabilities will be acknowledged here (with permission).
