// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexSwitch5",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexSwitch5Core", targets: ["CodexSwitch5Core"]),
        .executable(name: "CodexSwitch5", targets: ["CodexSwitch5"]),
    ],
    targets: [
        .target(name: "CodexSwitch5Core"),
        .executableTarget(
            name: "CodexSwitch5",
            dependencies: ["CodexSwitch5Core"]
        ),
        .executableTarget(
            name: "CodexSwitch5CoreChecks",
            dependencies: ["CodexSwitch5Core"]
        ),
    ]
)
