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
        )
    ],
    targets: [
        .executableTarget(
            name: "Glitcho",
            resources: []
        ),
        .testTarget(
            name: "GlitchoTests",
            dependencies: ["Glitcho"]
        )
    ]
)
