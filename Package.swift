// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "S400Menu", platforms: [.macOS(.v13)], products: [
    .executable(name: "S400Menu", targets: ["S400Menu"])
], dependencies: [
    .package(path: "Vendor/GTMAppAuth"), .package(path: "Vendor/AppAuth-iOS")
], targets: [
    .target(name: "S400Core", dependencies: ["MiHomeCompatibility"]),
    .executableTarget(name: "S400Menu", dependencies: ["S400Core", .product(name: "GTMAppAuth", package: "GTMAppAuth"), .product(name: "AppAuth", package: "AppAuth-iOS")]),
    .testTarget(name: "S400CoreTests", dependencies: ["S400Core", "S400Menu"]),
    // Pure calculation module; production ingestion uses it through S400Core.
    .target(name: "MiHomeCompatibility"),
    .testTarget(name: "MiHomeCompatibilityTests", dependencies: ["MiHomeCompatibility", "S400Core"], resources: [.copy("Fixtures")])
])
