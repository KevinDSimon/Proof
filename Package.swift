// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Proof",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        .library(name: "ProofKit", targets: ["ProofKit"]),
        .library(name: "ProofUI", targets: ["ProofUI"]),
    ],
    targets: [
        .target(name: "ProofKit"),
        // The app model and views the Mac and iOS apps share. SwiftUI only, never AppKit or UIKit.
        // Resources holds the manila folder image the sidebars and the iPhone grid show (decision 0059).
        .target(name: "ProofUI", dependencies: ["ProofKit"], resources: [.process("Resources")]),
        // Reference renders and sample metadata are read from source by path, not bundled.
        .testTarget(name: "ProofKitTests", dependencies: ["ProofKit"], exclude: ["References", "Samples"]),
    ]
)
