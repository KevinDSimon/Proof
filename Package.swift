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
        .testTarget(name: "ProofKitTests", dependencies: ["ProofKit"]),
    ]
)
