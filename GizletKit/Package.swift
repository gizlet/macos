// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GizletKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GizletCore", targets: ["GizletCore"]),
        .library(name: "GizletUI", targets: ["GizletUI"]),
        .executable(name: "GizletDev", targets: ["GizletDev"]),
    ],
    targets: [
        .target(
            name: "GizletCore",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedLibrary("z"),
            ]
        ),
        .target(name: "GizletUI", dependencies: ["GizletCore"]),
        .executableTarget(name: "GizletDev", dependencies: ["GizletUI"]),
        .testTarget(name: "GizletCoreTests", dependencies: ["GizletCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
