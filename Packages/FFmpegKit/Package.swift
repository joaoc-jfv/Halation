// swift-tools-version: 6.0
import PackageDescription

// FFmpeg n9 (the libraries Halation's MKV support needs: demuxing and the mp4 muxer), taken as prebuilt static
// xcframeworks from the MPVKit project's release 1.1.0-n9.0.2. These are the LGPL builds (plain names, not "-GPL").
// MPVKit itself is not used: it also pulls in mpv, libass, shaders and more than a gigabyte of other binaries.
// Static LGPL linking: see PLAN.md section 9 (the app must stay relinkable).
let release = "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2"

let package = Package(
    name: "FFmpegKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FFmpegKit", targets: ["FFmpegKit"]),
    ],
    targets: [
        .target(
            name: "FFmpegKit",
            dependencies: ["Libavcodec", "Libavformat", "Libavutil", "Libswresample", "gmp", "gnutls", "nettle", "hogweed", "Libdav1d", "Libuavs3d", "lcms2"],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                // Nothing imports these, so the compiler wouldn't link them by itself. The FFmpeg archives above
                // were built against them (TLS, RTMP, AV1, colour management) and reference their symbols.
                .linkedFramework("gnutls"),
                .linkedFramework("nettle"),
                .linkedFramework("hogweed"),
                .linkedFramework("gmp"),
                .linkedFramework("Libdav1d"),
                .linkedFramework("Libuavs3d"),
                .linkedFramework("lcms2"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("resolv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),
        .binaryTarget(name: "Libavcodec", url: "\(release)/Libavcodec.xcframework.zip",
                      checksum: "d516e904490c711c2875dd238d7d8d9f4f46e335829cb8ee7e0e1623e952e372"),
        .binaryTarget(name: "Libavformat", url: "\(release)/Libavformat.xcframework.zip",
                      checksum: "0a840424d7a2d971687d6e96d995e21420cce1b27dae74687ff4f5f31dc36e73"),
        .binaryTarget(name: "Libavutil", url: "\(release)/Libavutil.xcframework.zip",
                      checksum: "0ca518d2a3eab22763310d8bcdc977494ddb3daf3dc3b73a2ed84c5eefc13f75"),
        .binaryTarget(name: "Libswresample", url: "\(release)/Libswresample.xcframework.zip",
                      checksum: "49edabb3c2e7fb97e6458f2e6a2fea66ab567b55258141e598fecfcd29cd9eeb"),
        // Libraries the FFmpeg archives above reference. Same release assets MPVKit's own manifest uses.
        .binaryTarget(name: "gnutls", url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gnutls.xcframework.zip",
                      checksum: "3dbec5809339189bf9679e218c6cff387ebf8fb72745927835afc2678f5c9f4d"),
        .binaryTarget(name: "nettle", url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/nettle.xcframework.zip",
                      checksum: "0fdf3ebf8bd7b8bc8eee837cf27261cb4c52ae520b6576a2f468656aa1691e02"),
        .binaryTarget(name: "hogweed", url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/hogweed.xcframework.zip",
                      checksum: "25727c9fa67287fa0a4f4722f88bb8be669b23cd7e837e2d00870eb8a25d3f27"),
        .binaryTarget(name: "gmp", url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gmp.xcframework.zip",
                      checksum: "ad33c7a08f4cdcb9924c8f0e6d9a054dad33d7794b97667bf8b6fb2b236ae585"),
        .binaryTarget(name: "Libdav1d", url: "https://github.com/mpvkit/libdav1d-build/releases/download/1.5.3/Libdav1d.xcframework.zip",
                      checksum: "d1a32ae6a1f0193e9f05c44c9176844af7f6d2a58cb33843f6f1b8dfd9224083"),
        .binaryTarget(name: "Libuavs3d", url: "https://github.com/mpvkit/libuavs3d-build/releases/download/1.2.1-fix/Libuavs3d.xcframework.zip",
                      checksum: "bd5256081486d16c51c868d755bf70266c424b54c895269580de44ec6707f789"),
        .binaryTarget(name: "lcms2", url: "https://github.com/mpvkit/lcms2-build/releases/download/2.17.0/lcms2.xcframework.zip",
                      checksum: "dc0dce0606f6ab6841a8ec5a6bd4448e2f3ef00661a050460f806c9393dc6982"),
    ]
)
