// swift-tools-version:5.9
import PackageDescription

// TinRoof Transcode (TRT). The display name of the built .app is
// set by APP_NAME in scripts/build_app.sh and read at runtime from the bundle.
let package = Package(
    name: "TinRoofTranscode",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TinRoofTranscode", targets: ["AppMain"]),
    ],
    targets: [
        // FFmpeg libraries discovered through pkg-config (Homebrew: `brew install ffmpeg pkg-config`).
        .systemLibrary(
            name: "CFFmpeg",
            path: "Sources/CFFmpeg",
            pkgConfig: "libavformat libavcodec libavutil libswscale libswresample",
            providers: [.brew(["ffmpeg"])]
        ),
        // Small C layer over libav*: probing, keyframe indexing, decoding to BGRA / float PCM.
        .target(
            name: "CMedia",
            dependencies: ["CFFmpeg"],
            path: "Sources/CMedia"
        ),
        // Platform-independent model: edit lists, export settings, ffmpeg command
        // construction, jobs, batch queue, presets.
        .target(
            name: "MediaCore",
            dependencies: ["CMedia"],
            path: "Sources/MediaCore"
        ),
        // AppKit / SwiftUI application.
        .executableTarget(
            name: "AppMain",
            dependencies: ["MediaCore", "CMedia"],
            path: "Sources/AppMain"
        ),
        .testTarget(
            name: "MediaCoreTests",
            dependencies: ["MediaCore", "CMedia"],
            path: "Tests/MediaCoreTests"
        ),
    ]
)
