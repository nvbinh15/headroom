// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HeadroomKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HeadroomKit", targets: ["HeadroomKit"]),
        .executable(name: "headroom", targets: ["headroom"])
    ],
    targets: [
        .target(name: "HeadroomKit"),
        .executableTarget(
            name: "headroom",
            dependencies: ["HeadroomKit"]
        ),
        .testTarget(
            name: "HeadroomKitTests",
            dependencies: ["HeadroomKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
