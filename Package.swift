// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LanBox",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "LanBox",
            path: "Sources/LanBox",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "LanBoxTests",
            dependencies: ["LanBox"],
            path: "Tests/LanBoxTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
