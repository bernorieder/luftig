// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "spike-textkit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "spike", path: "Sources/spike"),
    ],
    swiftLanguageModes: [.v5]
)
