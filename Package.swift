// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cafectl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "cafectl", targets: ["cafectl"]),
    ],
    targets: [
        .executableTarget(name: "cafectl"),
        .testTarget(name: "CafectlTests", dependencies: ["cafectl"]),
    ]
)
