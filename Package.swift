// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "VoiceToText",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(name: "VoiceToText", targets: ["VoiceToText"]),
        // Dynamic variant, used by scripts/build-xcframework.sh to produce a binary framework.
        .library(name: "VoiceToTextDynamic", type: .dynamic, targets: ["VoiceToText"])
    ],
    targets: [
        .target(name: "VoiceToText"),
        .testTarget(name: "VoiceToTextTests", dependencies: ["VoiceToText"])
    ]
)
