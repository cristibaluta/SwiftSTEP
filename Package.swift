// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftSTEP",
    platforms: [.macOS(.v13), .iOS(.v15)],
    products: [
        .library(name: "SwiftSTEP", targets: ["SwiftSTEP"]),
        .executable(name: "SwiftSTEPDemo", targets: ["SwiftSTEPDemo"])
    ],
    targets: [
        .target(name: "SwiftSTEP"),
        .executableTarget(name: "SwiftSTEPDemo",
                          dependencies: ["SwiftSTEP"],
                          resources: [
                              .process("Sources/SwiftSTEPDemo/Shaders.metal")
                          ]),
        .testTarget(name: "SwiftSTEPTests", dependencies: ["SwiftSTEP"]),
    ]
)
