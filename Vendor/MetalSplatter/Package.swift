// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "MetalSplatter",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(name: "PLYIO", targets: ["PLYIO"]),
        .library(name: "SplatIO", targets: ["SplatIO"]),
        .library(name: "MetalSplatter", targets: ["MetalSplatter"])
    ],
    targets: [
        .target(
            name: "PLYIO",
            path: "PLYIO",
            sources: ["Sources"]
        ),
        .target(
            name: "SplatIO",
            dependencies: ["PLYIO"],
            path: "SplatIO",
            exclude: [
                "Sources/SPZSceneReader.swift",
                "Sources/SPZSceneWriter.swift"
            ],
            sources: ["Sources"]
        ),
        .target(
            name: "MetalSplatter",
            dependencies: ["PLYIO", "SplatIO"],
            path: "MetalSplatter",
            sources: ["Sources"],
            resources: [.process("Resources")]
        )
    ],
    swiftLanguageModes: [.v6]
)
