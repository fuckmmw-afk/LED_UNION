// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LEDUnion",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "LEDUnionCore", targets: ["LEDUnionCore"]),
        .library(name: "LEDUnionApp", targets: ["LEDUnionApp"]),
    ],
    targets: [
        .target(name: "LEDUnionCore", path: "Sources/LEDUnionCore"),
        .target(name: "LEDUnionApp", dependencies: ["LEDUnionCore"], path: "Sources/LEDUnionApp"),
        .testTarget(name: "LEDUnionCoreTests", dependencies: ["LEDUnionCore"], path: "Tests/LEDUnionCore"),
    ]
)
