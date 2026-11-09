// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DemoImages",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DemoImages",
            path: "Sources/DemoImages"
        )
    ]
)
