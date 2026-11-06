// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Subline",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SublineCore"),
        .executableTarget(name: "Subline", dependencies: ["SublineCore"]),
        .executableTarget(name: "subline-host", dependencies: ["SublineCore"]),
        .testTarget(name: "SublineCoreTests", dependencies: ["SublineCore"]),
    ],
    swiftLanguageModes: [.v5]
)
