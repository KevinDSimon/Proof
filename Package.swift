// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Proof",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ProofKit", targets: ["ProofKit"]),
    ],
    targets: [
        .target(name: "ProofKit"),
        .testTarget(name: "ProofKitTests", dependencies: ["ProofKit"]),
    ]
)
