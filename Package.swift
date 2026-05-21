// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TermIMS",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TermIMS", targets: ["TermIMS"])
    ],
    targets: [
        .executableTarget(
            name: "TermIMS",
            path: "Sources/TermIMS"
        )
    ]
)
