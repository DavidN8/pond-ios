// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "MatchaProtocol",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "MatchaProtocol", targets: ["MatchaProtocol"])
    ],
    targets: [
        .target(name: "MatchaProtocol"),
        .testTarget(name: "MatchaProtocolTests",
                    dependencies: ["MatchaProtocol"],
                    resources: [.copy("Fixtures")])
    ]
)
