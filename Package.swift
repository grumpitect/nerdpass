// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nerdpass",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PassCore", targets: ["PassCore"])],
    targets: [
        // Everything testable: picking the input, the start/stop/reconnect logic, volume, settings, menu layout.
        .target(name: "PassCore"),
        // The menu bar app itself (AppKit + SwiftUI + AVFoundation glue only).
        .executableTarget(name: "App", dependencies: ["PassCore"]),
        .testTarget(name: "PassCoreTests", dependencies: ["PassCore"]),
    ]
)
