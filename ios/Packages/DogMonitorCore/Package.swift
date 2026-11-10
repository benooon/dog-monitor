// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DogMonitorCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DogMonitorCore", targets: ["DogMonitorCore"]),
    ],
    targets: [
        .target(name: "DogMonitorCore"),
        .testTarget(name: "DogMonitorCoreTests", dependencies: ["DogMonitorCore"]),
    ]
)
