import Crypto
import NIOCore
import NIOSSH

/// Erbjuder autentiseringsuppgifter till servern. NIOSSH frågar oss om nästa
/// metod tills en lyckas eller alla är slut. När vi ger upp (returnerar nil)
/// anropas `onGiveUp` — NIOSSH stänger inte alltid anslutningen självt vid
/// misslyckad auth, så vi använder den signalen för att inte hänga.
final class SSHUserAuth: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let auth: SSHAuth
    private let onGiveUp: () -> Void
    private var offered = false

    init(username: String, auth: SSHAuth, onGiveUp: @escaping () -> Void) {
        self.username = username
        self.auth = auth
        self.onGiveUp = onGiveUp
    }

    private func giveUp(_ promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        onGiveUp()
        promise.succeed(nil)
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // Vi erbjuder varje uppgift en gång; misslyckas den ger vi upp.
        guard !offered else {
            giveUp(nextChallengePromise)
            return
        }
        offered = true

        switch auth {
        case .password(let pw):
            guard availableMethods.contains(.password) else {
                giveUp(nextChallengePromise)
                return
            }
            let offer = NIOSSHUserAuthenticationOffer(
                username: username, serviceName: "",
                offer: .password(.init(password: pw)))
            nextChallengePromise.succeed(offer)

        case .ed25519Seed(let seed):
            guard availableMethods.contains(.publicKey),
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
                giveUp(nextChallengePromise)
                return
            }
            let priv = NIOSSHPrivateKey(ed25519Key: key)
            let offer = NIOSSHUserAuthenticationOffer(
                username: username, serviceName: "",
                offer: .privateKey(.init(privateKey: priv)))
            nextChallengePromise.succeed(offer)
        }
    }
}
