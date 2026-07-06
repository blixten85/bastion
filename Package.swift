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
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.13.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),
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
