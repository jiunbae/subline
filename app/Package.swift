// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NowPlaying",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NowPlayingCore"),
        .executableTarget(name: "NowPlaying", dependencies: ["NowPlayingCore"]),
        .executableTarget(name: "np-host", dependencies: ["NowPlayingCore"]),
        .testTarget(name: "NowPlayingCoreTests", dependencies: ["NowPlayingCore"]),
    ],
    swiftLanguageModes: [.v5]
)
