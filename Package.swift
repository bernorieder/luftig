// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "luftig",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "luftig", targets: ["luftig"]),
    ],
    targets: [
        // Pure Swift + Foundation. No AppKit. Markdown -> style runs.
        .target(name: "MarkdownKit", path: "Sources/MarkdownKit", exclude: ["README.md"]),

        // The macOS app (AppKit, NSDocument based).
        .executableTarget(
            name: "luftig",
            dependencies: ["MarkdownKit"],
            path: "Sources/luftig",
            linkerSettings: [
                // The look on macOS 26 and later. SwiftPM records the deployment target (14.0) as the SDK version too, and AppKit then
                // gives the app the CLASSIC window chrome, scrollers and bordered buttons. This re-stamps the executable: minos stays
                // 14.0 (the app still runs on macOS 14), the SDK version becomes 27.0 (the SDK this was built and checked with), so
                // newer systems draw the app with their current design. `otool -l luftig | grep -A5 LC_BUILD_VERSION` shows it;
                // Scripts/build-app.sh checks it. TO SWITCH THE NEW LOOK OFF AGAIN: delete the `linkerSettings:` argument (this block).
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "27.0"]),
            ]
        ),

        // XCTest and swift-testing are NOT available on this machine (Command Line Tools only),
        // so tests are a plain executable: `swift run -c release mdkit-checks`. Exit code != 0 on failure.
        .executableTarget(
            name: "mdkit-checks",
            dependencies: ["MarkdownKit"],
            path: "Sources/MarkdownKitChecks"
        ),
    ],
    swiftLanguageModes: [.v5]
)
