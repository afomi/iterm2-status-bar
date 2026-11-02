// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iTermSidebar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "iTermSidebar", path: "Sources/iTermSidebar"),
        .testTarget(name: "iTermSidebarTests", dependencies: ["iTermSidebar"], path: "Tests/iTermSidebarTests"),
    ]
)
