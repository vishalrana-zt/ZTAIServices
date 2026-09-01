// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZTAIServices",
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
