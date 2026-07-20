import Foundation

#if !os(iOS)
/// Kör en lokal subprocess och samlar in stdout/stderr/exitkod. Delad av
/// alla lokala CLI-integrationer (`TailscaleStatus.fetchLocal`,
/// `BitwardenClient`) — extraherad hit istället för att dupliceras, eftersom
/// den konkurrenta pipe-läsningen nedan undviker ett äkta dödläge (se
/// kommentaren i `run(...)`), inte bara boilerplate värt att kopiera.
///
/// Finns INTE på iOS — `Foundation.Process` är otillgängligt där (sandboxen
/// tillåter inte att spawna godtyckliga subprocesser).
enum ProcessRunner {
    struct Result: Sendable {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    static func run(executableURL: URL, arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // stdout och stderr MÅSTE läsas konkurrent, inte sekventiellt: om
        // barnprocessen skriver tillräckligt till stderr för att fylla OS-
        // pipebufferten medan vi fortfarande blockerar i den sekventiella
        // readDataToEndOfFile() på stdout, blockerar barnet i sin tur på
        // write() till stderr — ett klassiskt Process/Pipe-dödläge (ingen
        // sida kan göra framsteg).
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading
        let stdoutThread = ResultThread { stdoutHandle.readDataToEndOfFile() }
        let stderrThread = ResultThread { stderrHandle.readDataToEndOfFile() }
        stdoutThread.start()
        stderrThread.start()
        let outData = stdoutThread.join()
        let errData = stderrThread.join()
        process.waitUntilExit()
        return Result(stdout: outData, stderr: errData, exitCode: process.terminationStatus)
    }
}

// Samma plattformsvillkor som `run(executableURL:arguments:)` ovan (INTE
// `canImport(Darwin) || canImport(Glibc)`, som uteslöt Windows och gav
// "cannot find 'ResultThread' in scope" i windowsapp-build — `Thread`/
// `DispatchSemaphore` finns även i swift-corelibs-foundation på Windows).
/// Kör en synkron closure på en egen `Thread` och blockerar tills den är
/// klar — precis vad som krävs för att läsa `stdout`/`stderr` konkurrent
/// utan att dela en `var` mellan closures (vilket Swift 6:s strikta
/// datakapplöpningskontroll avvisar).
private final class ResultThread<T>: @unchecked Sendable {
    private let work: () -> T
    private var result: T?
    private let semaphore = DispatchSemaphore(value: 0)

    init(_ work: @escaping () -> T) {
        self.work = work
    }

    func start() {
        Thread { [self] in
            result = work()
            semaphore.signal()
        }.start()
    }

    func join() -> T {
        semaphore.wait()
        return result!
    }
}
#endif
