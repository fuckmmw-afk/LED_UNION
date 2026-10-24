// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LEDNativeBLEPlugin",
    platforms: [.iOS(.v17)],
    products: [.library(name: "LEDNativeBLEPlugin", targets: ["LEDNativeBLEPlugin"])],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", exact: "8.5.3"),
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "LEDNativeBLEPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "LEDUnionCore", package: "LED_UNION"),
                .product(name: "LEDUnionCore", package: "LED_UNION"),
            ],
            path: "."
        )
    ]
)
