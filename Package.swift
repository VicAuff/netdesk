// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NetDesk",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CleanCore"),
        .executableTarget(name: "NetDesk", dependencies: ["CleanCore"]),
        .executableTarget(name: "netdesk-scan", dependencies: ["CleanCore"]),
        .testTarget(name: "CleanCoreTests", dependencies: ["CleanCore"]),
    ],
    swiftLanguageModes: [.v5]
)
