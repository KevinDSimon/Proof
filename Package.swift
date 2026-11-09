// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Proof",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        .library(name: "ProofKit", targets: ["ProofKit"]),
    ],
    targets: [
        .target(name: "ProofKit"),
        // Reference renders are read from source by path, not bundled.
        .testTarget(name: "ProofKitTests", dependencies: ["ProofKit"], exclude: ["References"]),
    ]
)
