// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MomentsCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MomentsCore", targets: ["MomentsCore"]),
    ],
    targets: [
        .target(name: "MomentsCore"),
        .testTarget(name: "MomentsCoreTests", dependencies: ["MomentsCore"]),
    ]
)
