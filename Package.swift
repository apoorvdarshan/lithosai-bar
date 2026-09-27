// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LithosAIBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LithosAIBar",
            path: "Sources/LithosAIBar"
        )
    ]
)