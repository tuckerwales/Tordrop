// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TorDrop",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TorDrop",
            path: "Sources/TorDrop"
        )
    ]
)
