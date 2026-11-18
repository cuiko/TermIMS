// swift-tools-version: 6.0

import PackageDescription

// Language mode is pinned to v5 across every target: the executable is AppKit
// glue written before strict concurrency, and this split is meant to be a pure
// refactor. Moving to Swift 6 mode is a separate, opt-in step.
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "TermIMS",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TermIMS", targets: ["TermIMS"])
    ],
    targets: [
        // Pure, side-effect-free logic. No AppKit, no syscalls — so it can be
        // unit-tested directly without Accessibility permission or a live
        // terminal.
        .target(
            name: "TermIMSCore",
            path: "Sources/TermIMSCore",
            swiftSettings: swift5
        ),
        // The app: AppKit, Accessibility, sysctl, IPC.
        .executableTarget(
            name: "TermIMS",
            dependencies: ["TermIMSCore"],
            path: "Sources/TermIMS",
            swiftSettings: swift5
        ),
        .testTarget(
            name: "TermIMSCoreTests",
            dependencies: ["TermIMSCore"],
            path: "Tests/TermIMSCoreTests",
            swiftSettings: swift5
        ),
    ]
)
