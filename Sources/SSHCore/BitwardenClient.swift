import Foundation

/// Hämtar ett värdlösenord ur en LOKALT installerad Bitwarden CLI (`bw`) —
/// gratis kärnfunktion, inget betalt tillägg krävs (till skillnad från
/// 1Password/LastPass CLI-motsvarigheter). Bastion loggar aldrig in/låser
/// upp valvet självt; förutsätter att användaren redan kört `bw login` och
/// har en giltig sessionsnyckel (miljövariabeln `BW_SESSION`, precis som
/// `bw` själv förväntar sig utanför interaktiv `bw unlock`).
///
/// Finns INTE på iOS/tvOS/watchOS — samma sandbox-begränsning som
/// `TailscaleStatus.fetchLocal` (`Foundation.Process` otillgängligt på alla
/// tre). iOS behöver native AutoFill/`ASCredentialProviderExtension`
/// istället, ett separat, Xcode/device-only arbete som inte kan byggas
/// eller verifieras här. Felenumet exkluderas här också — det finns bara
/// för att beskriva fel `BitwardenClient` kan kasta, ingen anledning att
/// vara publikt på plattformar där klienten själv inte existerar.
#if !os(iOS) && !os(tvOS) && !os(watchOS)
public enum BitwardenClientError: Error, Sendable, Equatable {
    case commandFailed(exitCode: Int32, stderr: String)
    case emptyPassword
}

public enum BitwardenClient {
    /// `itemID` kan vara ett Bitwarden-item-id (UUID) eller ett unikt namn —
    /// `bw get password` accepterar båda. `session` skickas via miljövariabeln
    /// `BW_SESSION` (inte som argv `--session`, vilket läcker via `/proc/*/cmdline`)
    /// om satt, annars faller `bw` tillbaka på egen sessionscache/miljö.
    public static func fetchPassword(
        itemID: String,
        session: String? = ProcessInfo.processInfo.environment["BW_SESSION"],
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        binaryName: String = "bw"
    ) throws -> String {
        var arguments = binaryName.isEmpty ? [] : [binaryName]
        // --nointeraction: utan sessionsnyckel/med en utgången session skulle
        // `bw` annars fråga interaktivt efter huvudlösenordet — en process
        // startad från Bastion har ingen terminal att fråga i, så det hade
        // bara hängt tills anropande kod (execute()/openShell()-liknande
        // timeouter) gett upp, i stället för att faila direkt.
        arguments += ["get", "password", itemID, "--nointeraction"]
        var environment: [String: String]? = nil
        if let session, !session.isEmpty {
            environment = ["BW_SESSION": session]
        }
        let result = try ProcessRunner.run(executableURL: executableURL, arguments: arguments, environment: environment)
        guard result.exitCode == 0 else {
            throw BitwardenClientError.commandFailed(
                exitCode: result.exitCode,
                stderr: String(data: result.stderr, encoding: .utf8) ?? "")
        }
        // INTE trimmat rakt av — bara den avslutande radbrytningen som `bw`
        // själv lägger till på stdout, aldrig inre whitespace (samma
        // lärdom som PR #173: att trimma ett riktigt lösenord korrumperar
        // det om det avsiktligt innehåller ledande/efterföljande blanksteg).
        var password = String(data: result.stdout, encoding: .utf8) ?? ""
        while password.hasSuffix("\n") || password.hasSuffix("\r") {
            password.removeLast()
        }
        guard !password.isEmpty else { throw BitwardenClientError.emptyPassword }
        return password
    }
}
#endif
