// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZTAIServiceEngine",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "ZTAIServiceEngine",
            targets: ["ZTAIServiceEngine"]
        )
    ],
    targets: [
        .target(
            name: "ZTAIServiceEngine",
            path: "ZTSpeechToText/Core",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
