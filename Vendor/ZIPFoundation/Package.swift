// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ZIPFoundation",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "ZIPFoundation", targets: ["ZIPFoundation"])],
    targets: [
        .target(name: "CLibdeflate", sources: ["lib"], publicHeadersPath: "include",
                cSettings: [.headerSearchPath(".")]),
        .target(name: "ZIPFoundation", dependencies: ["CLibdeflate"], resources: [.copy("Resources/PrivacyInfo.xcprivacy")])],
    swiftLanguageModes: [.v6]
)
