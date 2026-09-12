// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftTorrent",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17)
    ],
    products: [
        .library(name: "SwiftTorrent", targets: ["SwiftTorrent"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SwiftTorrent",
            dependencies: []
        ),
        .testTarget(
            name: "SwiftTorrentTests",
            dependencies: ["SwiftTorrent"]
        ),
    ]
)
