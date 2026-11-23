// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BVRD",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BVRD", path: "Sources/BVRD"),
        .executableTarget(name: "BVRDPlayer", path: "Sources/BVRDPlayer"),
    ]
)
