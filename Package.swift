// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tonearm",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Tonearm",
            path: "Sources/Tonearm"
        ),
    ]
)
