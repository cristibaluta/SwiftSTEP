// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftSTEP",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SwiftSTEP", targets: ["SwiftSTEP"]),
    ],
    targets: [
        .target(name: "SwiftSTEP"),
        .testTarget(name: "SwiftSTEPTests", dependencies: ["SwiftSTEP"]),
    ],
    swiftLanguageModes: [.v5]
)
