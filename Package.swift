// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ZipMello",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "ZipMello", targets: ["ZipMello"]),
        .library(name: "ZipMelloConsumers", targets: ["ZipMelloConsumers"]),
        .executable(name: "zipmello", targets: ["ZipMelloCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-system", exact: "1.8.1")
    ],
    targets: [
        .target(name: "ZipMello", dependencies: [.product(name: "SystemPackage", package: "swift-system")]),
        .target(name: "ZipMelloConsumers", dependencies: ["ZipMello"]),
        .executableTarget(name: "ZipMelloCLI", dependencies: ["ZipMello"]),
        .testTarget(name: "ZipMelloTests", dependencies: ["ZipMello", "ZipMelloConsumers"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
