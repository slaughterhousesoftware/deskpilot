// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DeskpilotKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DeskpilotKit", targets: ["DeskpilotKit"]),
    ],
    targets: [
        // Optimised in Debug too, for `make app` and Xcode runs (what ships is Release): unoptimised the
        // sleep card's pixel passes (`SleepCardPainter`, `ExactClosing`) take ~2 s per Day
        // chart instead of ~40 ms, stalling the Dashboard's Day/Week/Month switch.
        .target(name: "DeskpilotKit",
                swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .testTarget(
            name: "DeskpilotKitTests",
            dependencies: ["DeskpilotKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "DeskpilotKitLiveTests", dependencies: ["DeskpilotKit"]),
    ]
)
