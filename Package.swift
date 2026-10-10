// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickScreenControl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuickScreenControl",
            path: "Sources/QuickScreenControl",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]
        )
    ]
)
