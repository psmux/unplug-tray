// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UnplugTray",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "UnplugCore"),
        .executableTarget(
            name: "UnplugTray",
            dependencies: ["UnplugCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(name: "UnplugCoreTests", dependencies: ["UnplugCore"]),
    ]
)
