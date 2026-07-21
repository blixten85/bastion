#if os(tvOS)
import Foundation

/// Kopia av nycklarna i `App/SyncSettingsView.swift` — samma `UserDefaults`/
/// Keychain-nycklar så en synkinställning gjord på iPhone/Mac känns igen
/// här. `folder`/`dropbox` sätts aldrig av `TVSyncSettingsView` (ingen
/// Filer-app resp. Dropbox stödjer inte device-flow, se
/// `TVDeviceFlowOAuthManager.swift`), men om en tv-enhet av misstag delar
/// `UserDefaults` med en synkad iPhone-profil (den gör den inte idag, men
/// om det ändras) ska värdet ändå kunna LÄSAS utan krasch.
enum SyncKeys {
    static let enabled = "syncEnabled"
    static let passphraseKey = "syncPassphrase"
    static let transport = "syncTransport"
}
#endif
