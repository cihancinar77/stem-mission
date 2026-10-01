// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StemMission",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "StemMission", path: "Sources/StemMission")
    ]
)
