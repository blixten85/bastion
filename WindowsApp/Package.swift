// swift-tools-version:5.10
import PackageDescription

// Eget paket, som LinuxApp/ — se den filens kommentar för varför GUI-paket
// hålls skilda från rotens Package.swift. Windows-motsvarigheten till
// LinuxApp/, via SwiftCrossUIs WinUIBackend istället för GtkBackend. Bygget
// verifieras bara via CI (.github/workflows/windows-gui.yml, windows-latest-
// runnern) tills en riktig Windows-maskin finns att testa på.
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
                .product(name: "WinUIBackend", package: "swift-cross-ui"),
            ]
        )
    ]
)
