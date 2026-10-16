// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AIhistory",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AIhistory",
            path: "Sources/AIhistory"
        )
    ]
)
