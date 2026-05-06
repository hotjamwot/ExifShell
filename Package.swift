// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ExifShell",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ExifShell",
            path: "Sources"
        )
    ]
)