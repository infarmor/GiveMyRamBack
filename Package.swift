// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GiveMyRamBack",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "GiveMyRamBackCore",
            targets: ["GiveMyRamBackCore"]
        ),
        .executable(
            name: "GiveMyRamBack",
            targets: ["GiveMyRamBack"]
        )
    ],
    targets: [
        .target(
            name: "GiveMyRamBackCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "GiveMyRamBack",
            dependencies: ["GiveMyRamBackCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "GiveMyRamBackTests",
            dependencies: ["GiveMyRamBackCore"]
        )
    ]
)
