// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DesktopChibiFriendMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DesktopChibiFriendMac", targets: ["DesktopChibiFriendMac"])
    ],
    targets: [
        .executableTarget(
            name: "DesktopChibiFriendMac",
            path: "Sources/DesktopChibiFriendMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Network"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
