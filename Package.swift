// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Proof",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ProofKit", targets: ["ProofKit"]),
    ],
    targets: [
        .target(name: "ProofKit"),
        .testTarget(name: "ProofKitTests", dependencies: ["ProofKit"]),
    ]
)
