// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ZipMelloBenchmarks",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "zipmello-benchmark", targets: ["ZipMelloBenchmark"]),
        .executable(name: "zipmello-consumer-benchmark", targets: ["ZipMelloConsumerBenchmark"])
    ],
    dependencies: [
        .package(path: ".."),
        .package(path: "../Vendor/ZIPFoundation")
    ],
    targets: [
        .target(name: "UpstreamZIPFoundation", path: "Reference/ZIPFoundation/Sources/ZIPFoundation",
                resources: [.copy("Resources/PrivacyInfo.xcprivacy")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "ZipMelloBenchmark", dependencies: [
            .product(name: "ZipMello", package: "zipmello"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"), "UpstreamZIPFoundation"]),
        .executableTarget(name: "ZipMelloConsumerBenchmark", dependencies: [
            .product(name: "ZipMello", package: "zipmello"),
            .product(name: "ZipMelloConsumers", package: "zipmello"), "UpstreamZIPFoundation"])
    ],
    swiftLanguageModes: [.v6]
)
