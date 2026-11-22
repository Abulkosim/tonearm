// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tonearm",
    platforms: [.macOS(.v13)],
    dependencies: [
        // The one third-party dependency: Sparkle installs updates. Pinned to an exact
        // version. Dependabot proposes bumps; scripts/sparkle-tools.sh takes the command line
        // tools from the same SwiftPM download, so they always match.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "Tonearm",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Tonearm"
        ),
        .testTarget(
            name: "TonearmTests",
            dependencies: ["Tonearm"],
            path: "Tests/TonearmTests"
        ),
    ]
)
