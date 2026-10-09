// swift-tools-version: 6.0
import PackageDescription

// Throwaway spike for PLAN.md phase 2: can an MKV be remuxed (no re-encode) into fragmented MP4 that
// AVPlayer plays with HDR / Dolby Vision and Spatial Audio? Not part of the app target.
let package = Package(
    name: "MKVRemux",
    platforms: [.macOS("26.0")],
    dependencies: [
        // The LGPL product (plain "MPVKit"); "MPVKit-GPL" is the GPL one.
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.1.0-n9.0.2"),
    ],
    targets: [
        .executableTarget(
            name: "mkvremux",
            dependencies: [.product(name: "MPVKit", package: "MPVKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]  // throwaway script-style code with top-level state
        ),
        // Plays the remuxed pieces through AVPlayer as HLS, over a loopback server or an AVAssetResourceLoader.
        .executableTarget(
            name: "hlsprobe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Cuts each GOP into its own fragment with a fresh muxer (as an on-demand HLS server would),
        // rewriting the timestamps so the pieces line up on one timeline.
        .executableTarget(
            name: "mkvsegments",
            dependencies: [.product(name: "MPVKit", package: "MPVKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
