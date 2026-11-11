// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftSTEP",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "SwiftSTEP", targets: ["SwiftSTEP"]),
        .executable(name: "SwiftSTEPDemo", targets: ["SwiftSTEPDemo"])
    ],
    targets: [
        .target(name: "SwiftSTEP"),
        .executableTarget(name: "SwiftSTEPDemo",
                          dependencies: ["SwiftSTEP"],
                          // Paths are relative to the target folder (Sources/SwiftSTEPDemo).
                          resources: [
                              .process("Shaders.metal"),   // compiled into the bundle's default.metallib
                              .copy("Samples")             // hard-case models behind the toolbar dropdown
                          ]),
        .testTarget(name: "SwiftSTEPTests", dependencies: ["SwiftSTEP"]),
    ]
)
