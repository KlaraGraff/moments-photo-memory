// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SharingSpike",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SharingSpike", targets: ["SharingSpike"])
    ],
    targets: [
        .executableTarget(name: "SharingSpike")
    ]
)
