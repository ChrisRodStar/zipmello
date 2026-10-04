// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Benchmarks",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .executableTarget(
            name: "ZipMelloBenchmark",
            dependencies: [
                .product(name: "ZipMello", package: "zipmello"),
                .product(name: "ZipMelloConsumers", package: "zipmello"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/ZipMelloBenchmark"
        )
    ],
    swiftLanguageModes: [.v6]
)
