// swift-tools-version:5.10
import PackageDescription

// Eget paket, medvetet SKILT från rotens Package.swift. bastion-gui drar in
// SwiftCrossUI, vars kärnmodul (o)villkorligt beror på swift-mutex — ett
// beroende som kraschar stabila Swift 6.1.3 (swiftlang/swift#80759). Om den
// här targeten låg i rot-paketet skulle ett vanligt `swift build`/`swift test`
// där (SSHCore + bastion-cli, som funkar fint på stabil toolchain) plötsligt
// försöka bygga hela GUI-grafen också och krascha. Se root-READMEs
// "Bygg Linux-GUI:t" för toolchain-kravet.
let package = Package(
    name: "bastion-gui",
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/moreSwift/swift-cross-ui.git", from: "0.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "bastion-gui",
            dependencies: [
                .product(name: "SSHCore", package: "bastion"),
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                // GtkBackend direkt (inte DefaultBackend) — DefaultBackends
                // plattformsvillkorade WinUIBackend-beroende byggdes ändå på
                // en tidig SwiftPM-snapshot och kräver Windows-headers som
                // saknas på Linux. GtkBackend beror bara på SwiftCrossUI +
                // Gtk + CGtk, inga sådana problem.
                .product(name: "GtkBackend", package: "swift-cross-ui"),
            ]
        ),
        // Ett `.testTarget` kan `@testable import` ett `.executableTarget`
        // direkt (Swift 5.5+) — ingen omstrukturering till ett separat
        // bibliotekstarget krävs bara för att kunna testa.
        .testTarget(
            name: "bastion-guiTests",
            dependencies: [
                "bastion-gui",
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
            ]
        ),
    ]
)
