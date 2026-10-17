// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyDimmer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KeyDimmer", targets: ["KeyDimmer"]),
        .executable(name: "kdctl", targets: ["kdctl"]),
    ],
    targets: [
        .target(
            name: "KeyDimmerCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "KeyDimmer",
            dependencies: ["KeyDimmerCore"],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]
        ),
        .executableTarget(name: "kdctl", dependencies: ["KeyDimmerCore"]),
        .testTarget(name: "KeyDimmerCoreTests", dependencies: ["KeyDimmerCore"]),
    ],
    swiftLanguageModes: [.v5]
)
