// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LabelGUI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LabelGUI")
    ]
)
