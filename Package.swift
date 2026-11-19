// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BetterScreenSharing",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "VirtualDisplayShim",
            path: "Sources/VirtualDisplayShim",
            cSettings: [.unsafeFlags(["-fobjc-arc"])]
        ),
        .executableTarget(
            name: "BetterScreenSharing",
            dependencies: ["VirtualDisplayShim"],
            path: "Sources/BetterScreenSharing",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
