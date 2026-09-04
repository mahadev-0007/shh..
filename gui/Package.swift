// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SshmApp",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "SshmApp",
            dependencies: ["SwiftTerm", "Sparkle"],
            path: "Sources/SshmApp"
        )
    ]
)
