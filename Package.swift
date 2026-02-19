// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Glitcho",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "Glitcho",
            targets: ["Glitcho"]
        ),
        .executable(
            name: "GlitchoRecorderAgent",
            targets: ["GlitchoRecorderAgent"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Glitcho",
            resources: []
        ),
        .executableTarget(
            name: "GlitchoRecorderAgent"
        ),
        .testTarget(
            name: "GlitchoTests",
            dependencies: ["Glitcho"],
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
