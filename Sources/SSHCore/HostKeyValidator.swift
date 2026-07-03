import Crypto
import Foundation
import NIOCore
import NIOSSH

/// TOFU-validering av värdnyckeln mot en `KnownHosts`-lagring. Okänd värd lärs
/// in; oförändrad accepteras; ändrad avvisas (MITM-skydd). Ersätter den tidigare
/// "acceptera allt"-stubben.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let port: Int
    private let store: KnownHosts
    // NIOSSH stänger inte anslutningen självt när vi avvisar — sessionen får
    // signalen härigenom så pågående anrop inte hänger.
    private let onReject: (HostKeyInfo) -> Void

    init(host: String, port: Int, store: KnownHosts, onReject: @escaping (HostKeyInfo) -> Void) {
        self.host = host
        self.port = port
        self.store = store
        self.onReject = onReject
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let keyString = String(openSSHPublicKey: hostKey)
        switch store.check(host: host, port: port, keyString: keyString) {
        case .trusted, .learned:
            validationCompletePromise.succeed(())
        case .changed:
            let info = fingerprint(of: hostKey)
            onReject(info)
            validationCompletePromise.fail(SSHError.hostKeyRejected(info))
        }
    }
}

/// SHA256-fingeravtryck i samma format som `ssh-keygen -lf` ("SHA256:...").
func fingerprint(of key: NIOSSHPublicKey) -> HostKeyInfo {
    let ossh = String(openSSHPublicKey: key)     // "ssh-ed25519 AAAA..."
    let parts = ossh.split(separator: " ")
    let keyType = parts.first.map(String.init) ?? "?"
    var fp = "?"
    if parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) {
        var b64 = Data(SHA256.hash(data: blob)).base64EncodedString()
        while b64.hasSuffix("=") { b64.removeLast() }
        fp = "SHA256:" + b64
    }
    return HostKeyInfo(sha256Fingerprint: fp, keyType: keyType)
}
