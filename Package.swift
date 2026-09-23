// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SmartSpeedCompanion",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "SmartSpeedCompanion", targets: ["SmartSpeedCompanion"]),
    ],
    dependencies: [
        // Add dependencies here if needed, e.g. .package(url: "...", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "SmartSpeedCompanion",
            path: "SmartSpeedCompanion",
            exclude: ["Configuration/Info.plist", "Resources/Entitlements/SmartSpeedCompanion.entitlements"],
            resources: [
                // Overpass Bold (SIL OFL) — the Highway Gothic descendant the
                // speed-limit sign renderer draws with. Registered at runtime
                // from Bundle.module (CarPlayUI.registerSignFont).
                .copy("Resources/Fonts/Overpass-Bold.ttf"),
                .copy("Resources/Fonts/OFL.txt")
            ]
        ),
        .testTarget(
            name: "SmartSpeedCompanionTests",
            dependencies: ["SmartSpeedCompanion"],
            path: "SmartSpeedCompanionTests"
        ),
    ]
)
