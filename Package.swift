// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Heart",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Heart",
            path: "Sources/Heart"
        )
    ]
)
