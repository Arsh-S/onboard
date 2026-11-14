// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Onboard",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.1"),
    ],
    targets: [
        .target(
            name: "OnboardCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "TTSKit", package: "argmax-oss-swift"),
            ]
        ),
        .target(name: "OnboardOverlay", dependencies: ["OnboardCore"]),
        .target(name: "OnboardUI", dependencies: ["OnboardCore", "OnboardOverlay"]),
        .executableTarget(name: "Onboard", dependencies: ["OnboardCore", "OnboardOverlay", "OnboardUI"]),
        .testTarget(name: "OnboardCoreTests", dependencies: ["OnboardCore"]),
    ],
    swiftLanguageModes: [.v5]
)
