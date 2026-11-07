// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Buoy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Buoy", targets: ["Buoy"]),
        .library(name: "BuoyCore", targets: ["BuoyCore"]),
    ],
    targets: [
        // Pure model, scheduling logic, persistence, and backup. No UI.
        .target(
            name: "BuoyCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The SwiftUI macOS app.
        .executableTarget(
            name: "Buoy",
            dependencies: ["BuoyCore"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        // Self-contained check runner for BuoyCore (`swift run BuoyChecks`).
        // Used instead of XCTest/Swift Testing, which require a full Xcode install.
        .executableTarget(
            name: "BuoyChecks",
            dependencies: ["BuoyCore"]
        ),
    ]
)
