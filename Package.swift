// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZipMello",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
    ],
    products: [
        .library(name: "ZipMello", targets: ["ZipMello"]),
        .library(name: "ZipMelloConsumers", targets: ["ZipMelloConsumers"]),
        .executable(name: "zipmello", targets: ["ZipMelloCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-system", "1.4.0"..<"1.7.0")
    ],
    targets: [
        .target(name: "ZipMello", dependencies: [.product(name: "SystemPackage", package: "swift-system")]),
        .target(name: "ZipMelloConsumers", dependencies: ["ZipMello"]),
        .executableTarget(name: "ZipMelloCLI", dependencies: ["ZipMello"]),
        .testTarget(name: "ZipMelloTests", dependencies: ["ZipMello", "ZipMelloConsumers"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
