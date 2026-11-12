// swift-tools-version: 6.0
import Foundation
import PackageDescription

let cltTestingMacros = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let testSwiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: cltTestingMacros)
    ? [.unsafeFlags(["-load-plugin-library", cltTestingMacros])]
    : []

let package = Package(
    name: "LaunchLens",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .library(name: "LaunchLensCore", targets: ["LaunchLensCore"]),
        .executable(name: "LaunchLens", targets: ["LaunchLens"])
    ],
    targets: [
        .target(
            name: "LaunchLensCore"
        ),
        .executableTarget(
            name: "LaunchLens",
            dependencies: ["LaunchLensCore"]
        ),
        .testTarget(
            name: "LaunchLensCoreTests",
            dependencies: ["LaunchLensCore"],
            swiftSettings: testSwiftSettings
        )
    ],
    swiftLanguageModes: [.v5]
)
