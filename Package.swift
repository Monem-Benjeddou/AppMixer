// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AppMixer",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "AppMixer", path: "Sources/AppMixer")
    ]
)
