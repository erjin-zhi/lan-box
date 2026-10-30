// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LanBox",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "LanBox",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/LanBox",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
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
