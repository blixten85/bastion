import Crypto
import Foundation

/// PKCE (RFC 7636) — verifier/challenge-paret som gör att en publik
/// (native app) OAuth-klient kan logga in utan ett klienthemligt secret.
/// Ren logik, delas av alla kontointegrationer (Dropbox/Google Drive/OneDrive);
/// den interaktiva inloggningen (`ASWebAuthenticationSession`) och
/// token-utbytet är plattformsspecifika och ligger i `App/`.
public enum OAuthPKCE {
    /// Slumpad code verifier: 32 råa byte, base64url utan padding (43 tecken),
    /// inom RFC 7636:s tillåtna 43–128 tecken.
    public static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }

    /// `code_challenge` för `code_challenge_method=S256`: SHA256 av verifiern,
    /// base64url utan padding.
    public static func challenge(forVerifier verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(hash))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
