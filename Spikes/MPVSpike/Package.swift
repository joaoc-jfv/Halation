// swift-tools-version: 6.0
import PackageDescription

// Phase 3 spike: can libmpv (MPVKit's LGPL build) play into an AppKit window with HDR on macOS 26? See README.md.
let package = Package(
    name: "MPVSpike",
    platforms: [.macOS("14.0")],
    dependencies: [
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.1.0-n9.0.2"),
    ],
    targets: [
        .executableTarget(
            name: "mpvspike",
            dependencies: [.product(name: "MPVKit", package: "MPVKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
