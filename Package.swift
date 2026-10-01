// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StemSplitter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "StemSplitter", path: "Sources/StemSplitter")
    ]
)
