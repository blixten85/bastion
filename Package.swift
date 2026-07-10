// swift-tools-version:5.9
import PackageDescription

// Bastion — kärnbibliotek + CLI för att bevisa SSH-transporten.
// SSHCore och bastion-cli bygger på Linux OCH Apple (ren SwiftNIO).
// Terminal-UI:t (SwiftTerm) ligger i App/ och byggs bara i Xcode — se App/README.md.
// Linux-GUI:t (SwiftCrossUI/GTK4) ligger i LinuxApp/ som ett EGET paket — se
// LinuxApp/Package.swift för varför det medvetet inte ligger här.
let package = Package(
    name: "bastion",
    platforms: [
        .macOS(.v13), .iOS(.v16),
    ],
    products: [
        .library(name: "SSHCore", targets: ["SSHCore"]),
        .executable(name: "bastion-cli", targets: ["bastion-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.14.0"),
        // EXPERIMENT (claude/experiment-nio-pin-windows): pinnad till 2.86.2,
        // sista swift-nio-releasen med swift-tools-version:5.10 (2.87.0+ gick
        // till 6.0/6.1) — testar hypotesen att swift-nios EGEN Sendable/IPPROTO-
        // bugg på Windows (apple/swift-nio#3647) bara triggas när dess källor
        // kompileras i Swift 6-strict-concurrency-läge, vilket styrs av
        // PAKETETS EGEN deklarerade tools-version, inte konsumentens. Om
        // windows-gui.yml går grönt här: permanent fix tills uppströms löser
        // #3647 riktigt. Om inte: reverteras, ingen skada (egen branch).
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.86.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
    ],
    targets: [
        .target(
            name: "SSHCore",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "bastion-cli",
            dependencies: ["SSHCore"]
        ),
        .testTarget(
            name: "SSHCoreTests",
            dependencies: [
                "SSHCore",
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
    ]
)
