// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZTAIServices",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "ZTAIServices",
            targets: ["ZTAIServices"]
        )
    ],
    targets: [
        .target(
            name: "ZTAIServices",
            path: "ZTSpeechToText/Core",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
